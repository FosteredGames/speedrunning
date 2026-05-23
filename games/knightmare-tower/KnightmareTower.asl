// LiveSplit auto-splitter for Knightmare Tower (Steam, Unity 4.3.4f1, Mono 2.x, x86).
// SELF-CONTAINED -- no asl-help, no external libraries.
//
// Splits:
//   1. All missions complete + key obtained  (Master.stats.finishedMissions -> true)
//   2. Final boss killed                     (Master.stats.finishedStory   -> true)
//
// Timing:    IGT accumulates GameHelper.realTime across attempts.
// Auto-reset: when a New Game wipes the save.
//
// ============================================================================
// HOW IT WORKS
// ============================================================================
// LiveSplit's ASL can only READ memory, not call functions. To find Mono class
// statics by name, we walk Mono's internal data structures by hand:
//
//   mono.dll -> mono_get_root_domain prologue -> &mono_root_domain
//             -> MonoDomain.domain_assemblies (GSList<MonoAssembly*>)
//             -> find "Assembly-CSharp" -> MonoAssembly.image (MonoImage*)
//             -> MonoImage.class_cache (MonoInternalHashTable)
//                -> find MonoClass by name
//                -> walk MonoClass.fields to find MonoClassField by name
//                -> static field address =
//                     class.runtime_info.domain_vtables[0]
//                     + VTable header (0x2C) + vtable_size_in_bytes
//                     + field.offset
//
// ============================================================================
// IF SOMETHING DOESN'T RESOLVE
// ============================================================================
// Enable the "debug" setting and watch LiveSplit's debug log (DebugView++ is
// the easiest tool). Every step prints. The most likely culprits are the Mono
// struct offsets in the "OFFSETS" section below -- adjust there.
//
// LiveSplit setup:
//   1. Edit Layout -> + -> Control -> Scriptable Auto Splitter -> load this file.
//   2. Right-click LiveSplit -> Compare Against -> Game Time.
//      (The script provides gameTime{} and isLoading{return true;} so the
//       displayed timer will match the script's IGT.)

state("Knightmare Tower") {}

startup
{
    // Bump on every edit so you can confirm in DebugView that LiveSplit
    // reloaded the new file. Format: "YYYY-MM-DDTHH:MMZ (git-shorthash)".
    vars.ScriptVersion = "2026-05-23T08:50Z (31efcb3+state-log-always)";
    print("[KT] script loaded -- version " + vars.ScriptVersion);

    settings.Add("split_missions", true,  "Split when all missions complete (key obtained)");
    settings.Add("split_boss",     true,  "Split on final boss defeat");
    settings.Add("reset_new_game", true,  "Auto-reset when a New Game is started");
    settings.Add("debug",          true,  "Print Mono walker debug info");

    // settings in `startup` is a builder (no indexing). The Log lambda will
    // be called from `update` and friends, so close over a flag stored on
    // `vars` (which is shared across all blocks) instead. `init` populates
    // the real value once the reader-style settings is available.
    vars.LogEnabled = true;
    vars.Log = (Action<object>)(msg => {
        if (vars.LogEnabled) print("[KT] " + msg);
    });
    // Dedup repeated messages by category key. The first time a given key is
    // logged with a particular message, it prints; subsequent identical
    // messages are suppressed. A different message under the same key prints
    // again (so changes still surface). Init runs every ~500ms and most
    // discoveries are stable across passes, so this cuts log volume ~10x.
    vars.LastLogged = new Dictionary<string,string>();
    vars.LogOnce = (Action<string,string>)((key, msg) => {
        var d = (Dictionary<string,string>)vars.LastLogged;
        string prev;
        bool same = d.TryGetValue(key, out prev) && prev == msg;
        if (!same) {
            d[key] = msg;
            if (vars.LogEnabled) print("[KT] " + msg);
        }
    });

    // ====================================================================
    // OFFSETS -- Mono 2.x runtime, x86 (Unity 4.x). Tweak if init fails.
    // ====================================================================
    // GSList: { void *data; GSList *next; }
    vars.O_GSList_data       = 0x00;
    vars.O_GSList_next       = 0x04;
    // MonoDomain
    vars.O_Domain_Assemblies = 0xA0;
    // MonoAssembly
    vars.O_Assembly_Image    = 0x44;
    vars.O_Assembly_Name     = 0x10;   // char *name inside aname
    // MonoImage
    vars.O_Image_Name        = 0x08;
    vars.O_Image_ClassCache  = 0x2A0;
    // MonoInternalHashTable (relative to start of embedded struct)
    vars.O_IHT_size          = 0x18;
    vars.O_IHT_table         = 0x20;
    vars.O_IHT_NextClassSlot = 0x108;  // offset within MonoClass to "next in cache"
    // MonoClass
    vars.O_Class_Fields      = 0x60;
    vars.O_Class_FieldCount  = 0xF8;
    vars.O_Class_Name        = 0x2C;
    vars.O_Class_VTableSize  = 0x38;   // bytes
    vars.O_Class_RuntimeInfo = 0xC8;
    // MonoClassField (sizeof = 0x10)
    vars.O_Field_Size        = 0x10;
    vars.O_Field_Name        = 0x04;
    vars.O_Field_Offset      = 0x0C;
    // MonoClassRuntimeInfo: { int max_domain; MonoVTable *domain_vtables[]; }
    vars.O_RTInfo_VTables    = 0x04;
    // MonoVTable header size, followed by vtable_size function pointers,
    // then the static-field storage.
    vars.O_VTable_HeaderEnd  = 0x2C;

    // ---- Helpers (stashed on vars so init/update can use them) ----

    vars.ReadCStr = (Func<Process, IntPtr, string>)((proc, ptr) => {
        if (ptr == IntPtr.Zero) return null;
        try {
            byte[] buf = proc.ReadBytes(ptr, 128);
            if (buf == null) return null;
            int end = 0;
            while (end < buf.Length && buf[end] != 0) end++;
            return System.Text.Encoding.UTF8.GetString(buf, 0, end);
        } catch { return null; }
    });

    // Note: we DON'T use `proc.Modules` here because that uses the host
    // process's bitness for the module list -- if LiveSplit is 64-bit and
    // the game is 32-bit (Unity 4.x is x86 only), it throws Win32Exception.
    // Instead, `init` enumerates modules via ASL's wow64-safe `modules`
    // collection and stashes the base address on `vars.MonoBaseAddr`.
    vars.GetMonoBase = (Func<Process, long>)(proc => {
        try { return (long)(uint)vars.MonoBaseAddr; }
        catch { return 0L; }
    });

    // Resolve an exported symbol address by walking the PE export directory.
    vars.GetExport = (Func<Process, long, string, long>)((proc, modBase, name) => {
        try {
            int peOff = proc.ReadValue<int>((IntPtr)(modBase + 0x3C));
            // PE32 (x86) optional header: export dir at OptionalHeader + 0x60.
            long optHdr = modBase + peOff + 0x18;
            int expRva  = proc.ReadValue<int>((IntPtr)(optHdr + 0x60));
            if (expRva == 0) return 0L;
            long expDir = modBase + expRva;
            int numNames     = proc.ReadValue<int>((IntPtr)(expDir + 0x18));
            int addrFuncsRva = proc.ReadValue<int>((IntPtr)(expDir + 0x1C));
            int namesRva     = proc.ReadValue<int>((IntPtr)(expDir + 0x20));
            int ordsRva      = proc.ReadValue<int>((IntPtr)(expDir + 0x24));
            for (int i = 0; i < numNames; i++) {
                int nameRva = proc.ReadValue<int>((IntPtr)(modBase + namesRva + i*4));
                string s = ((Func<Process,IntPtr,string>)vars.ReadCStr)(proc, (IntPtr)(modBase + nameRva));
                if (s == name) {
                    short ord = proc.ReadValue<short>((IntPtr)(modBase + ordsRva + i*2));
                    int funcRva = proc.ReadValue<int>((IntPtr)(modBase + addrFuncsRva + ord*4));
                    return modBase + funcRva;
                }
            }
        } catch (Exception ex) {
            ((Action<object>)vars.Log)("getExport error: " + ex.Message);
        }
        return 0L;
    });

    // The big one -- runs once at startup of the game process. Returns true
    // when every address/offset we need has been resolved.
    vars.TryInitialize = (Func<Process, bool>)(proc => {
        var log     = (Action<object>)vars.Log;
        var logOnce = (Action<string,string>)vars.LogOnce;
        var rcstr   = (Func<Process,IntPtr,string>)vars.ReadCStr;
        var getExp  = (Func<Process,long,string,long>)vars.GetExport;

        // --- mono.dll base ---
        long monoBase = ((Func<Process,long>)vars.GetMonoBase)(proc);
        if (monoBase == 0) { log("mono.dll not loaded yet"); return false; }
        logOnce("monoDll", "mono.dll @ 0x" + monoBase.ToString("X"));

        // --- mono_get_root_domain export ---
        long fnGetRoot = getExp(proc, monoBase, "mono_get_root_domain");
        if (fnGetRoot == 0) { log("export mono_get_root_domain not found"); return false; }
        logOnce("monoGetRD", "mono_get_root_domain @ 0x" + fnGetRoot.ToString("X"));

        // --- expect prologue: A1 XX XX XX XX (mov eax, [imm32]) ---
        byte op0 = proc.ReadValue<byte>((IntPtr)fnGetRoot);
        if (op0 != 0xA1) {
            log("Unexpected prologue 0x" + op0.ToString("X") + " (want 0xA1); Mono build differs.");
            return false;
        }
        long pRootDomain = (long)(uint)proc.ReadValue<int>((IntPtr)(fnGetRoot + 1));
        long rootDomain  = (long)(uint)proc.ReadValue<int>((IntPtr)pRootDomain);
        if (rootDomain == 0) { log("root domain not initialized yet"); return false; }
        logOnce("monoDomain", "MonoDomain @ 0x" + rootDomain.ToString("X"));

        // --- AUTO-DISCOVER domain_assemblies + assembly_name offsets ---
        // Rather than trust my offset guesses, probe MonoDomain for any
        // pointer that -- when treated as a GSList head -- leads to an
        // object containing a recognizable assembly-name string.
        Func<long, string> tryReadAsCStr = (addr) => {
            try {
                byte[] buf = proc.ReadBytes((IntPtr)addr, 64);
                if (buf == null) return null;
                int end = 0;
                while (end < buf.Length && buf[end] != 0) end++;
                if (end == 0 || end > 60) return null;
                // Must be plausible printable ASCII.
                for (int k = 0; k < end; k++) {
                    if (buf[k] < 0x20 || buf[k] > 0x7E) return null;
                }
                return System.Text.Encoding.ASCII.GetString(buf, 0, end);
            } catch { return null; }
        };
        // Known assembly names we'd expect to find in any Mono runtime:
        var knownAsms = new HashSet<string> {
            "mscorlib", "System", "System.Core", "System.Xml", "Mono.Security",
            "Assembly-CSharp", "Assembly-CSharp-firstpass", "UnityEngine",
            "HOTween", "SteamworksManaged"
        };
        Func<long, bool> looksLikeHeap = (a) => (a >= 0x00010000 && a < 0x80000000);

        int foundDomOff = -1, foundNameOff = -1;
        string foundFirstName = null;
        long foundFirstAsm = 0;
        int foundKnownCount = 0;

        // Wider scan: 0x08 to 0x300, and wider name-offset candidates inside
        // the candidate "assembly" (covers cases where MonoAssemblyName isn't
        // the first embedded struct after the header).
        int[] nameOffCandidates = new int[] {
            0x00, 0x04, 0x08, 0x0C, 0x10, 0x14, 0x18, 0x1C, 0x20,
            0x24, 0x28, 0x2C, 0x30, 0x34, 0x38, 0x3C, 0x40
        };
        // Score each (dOff, nOff) by walking the GSList and counting how many
        // known assembly names appear. The CORRECT offset combo will find
        // many (Mono apps have ~8 standard assemblies); spurious matches find
        // 1-2 by coincidence. Pick the highest scorer.
        for (int dOff = 0x08; dOff <= 0x300; dOff += 4) {
            long gslist;
            try { gslist = (long)(uint)proc.ReadValue<int>((IntPtr)(rootDomain + dOff)); } catch { continue; }
            if (!looksLikeHeap(gslist)) continue;

            foreach (int nOff in nameOffCandidates) {
                int knownCount = 0;
                string firstName = null;
                long firstAsm = 0;
                long walkNode = gslist;
                int walkSteps = 0;
                while (walkNode != 0 && walkSteps < 32) {
                    long asmPtr;
                    try { asmPtr = (long)(uint)proc.ReadValue<int>((IntPtr)walkNode); } catch { break; }
                    if (asmPtr != 0 && looksLikeHeap(asmPtr)) {
                        long namePtr;
                        try { namePtr = (long)(uint)proc.ReadValue<int>((IntPtr)(asmPtr + nOff)); } catch { break; }
                        if (looksLikeHeap(namePtr)) {
                            string nm = tryReadAsCStr(namePtr);
                            if (nm != null && knownAsms.Contains(nm)) {
                                knownCount++;
                                if (firstName == null) { firstName = nm; firstAsm = asmPtr; }
                            }
                        }
                    }
                    long nxt;
                    try { nxt = (long)(uint)proc.ReadValue<int>((IntPtr)(walkNode + 4)); } catch { break; }
                    if (nxt == walkNode) break; // self-loop guard
                    walkNode = nxt;
                    walkSteps++;
                }
                if (knownCount > foundKnownCount) {
                    foundKnownCount = knownCount;
                    foundDomOff = dOff;
                    foundNameOff = nOff;
                    foundFirstName = firstName;
                    foundFirstAsm = firstAsm;
                }
            }
        }
        // Need at least 3 known assemblies to be confident; otherwise we're
        // probably matching a coincidence (e.g. one pointer that happens to
        // dereference to "System" by accident).
        if (foundKnownCount < 3) foundDomOff = -1;

        // Diagnostic fallback: even if the strict match failed, scan all heap-
        // ptr offsets and PRINT whatever plausible strings we can reach by
        // treating each as a GSList head. This lets us identify the right
        // offset by inspection of the output.
        if (foundDomOff < 0) {
            log("Strict auto-discovery failed; doing exploratory scan...");
            int printed = 0;
            for (int dOff = 0x08; dOff <= 0x300 && printed < 60; dOff += 4) {
                long gslist;
                try { gslist = (long)(uint)proc.ReadValue<int>((IntPtr)(rootDomain + dOff)); } catch { continue; }
                if (!looksLikeHeap(gslist)) continue;
                long firstAsm;
                try { firstAsm = (long)(uint)proc.ReadValue<int>((IntPtr)gslist); } catch { continue; }
                if (!looksLikeHeap(firstAsm)) continue;
                foreach (int nOff in nameOffCandidates) {
                    long namePtr;
                    try { namePtr = (long)(uint)proc.ReadValue<int>((IntPtr)(firstAsm + nOff)); } catch { continue; }
                    if (!looksLikeHeap(namePtr)) continue;
                    string nm = tryReadAsCStr(namePtr);
                    if (nm != null && nm.Length >= 3) {
                        log("  probe +0x" + dOff.ToString("X3") + " asm.+0x" + nOff.ToString("X2") + " -> \"" + nm + "\"");
                        printed++;
                        if (printed >= 60) break;
                    }
                }
            }
            log("AUTO-DISCOVERY FAILED -- MonoDomain dump follows:");
            try {
                byte[] dom = proc.ReadBytes((IntPtr)rootDomain, 0x300);
                if (dom != null) {
                    for (int i = 0; i < dom.Length; i += 16) {
                        var sb = new System.Text.StringBuilder();
                        sb.Append("  +0x" + i.ToString("X3") + ":");
                        for (int j = 0; j < 16 && i+j < dom.Length; j += 4) {
                            uint v = BitConverter.ToUInt32(dom, i+j);
                            sb.Append(" " + v.ToString("X8"));
                        }
                        log(sb.ToString());
                    }
                }
            } catch (Exception ex) { log("dump failed: " + ex.Message); }
            return false;
        }
        logOnce("domAsm", "AUTO-DISCOVERED: domain_assemblies @ +0x" + foundDomOff.ToString("X")
            + ", assembly_name @ +0x" + foundNameOff.ToString("X")
            + " (" + foundKnownCount + " known assemblies in list, first: " + foundFirstName + ")");
        vars.O_Domain_Assemblies = foundDomOff;
        vars.O_Assembly_Name     = foundNameOff;

        // --- now walk the assemblies list using the discovered offsets ---
        long node = (long)(uint)proc.ReadValue<int>((IntPtr)(rootDomain + foundDomOff));
        long imageAddr = 0;
        long asmForImageProbe = 0;
        int walked = 0;
        while (node != 0 && walked < 256) {
            long asmPtr = (long)(uint)proc.ReadValue<int>((IntPtr)(node + (int)vars.O_GSList_data));
            if (asmPtr != 0) {
                long namePtr = (long)(uint)proc.ReadValue<int>((IntPtr)(asmPtr + foundNameOff));
                string aname = tryReadAsCStr(namePtr);
                logOnce("asm:" + walked, "  asm[" + walked + "]: " + (aname ?? "<null>"));
                if (aname == "Assembly-CSharp") {
                    asmForImageProbe = asmPtr;
                    break;
                }
            }
            node = (long)(uint)proc.ReadValue<int>((IntPtr)(node + (int)vars.O_GSList_next));
            walked++;
        }
        if (asmForImageProbe == 0) { log("Assembly-CSharp not in assemblies list"); return false; }

        // --- AUTO-DISCOVER MonoAssembly.image offset ---
        // Scan ALL (iOff, inOff) combos that yield an "Assembly-CSharp"-named
        // image, then SCORE each by class_cache population (number of plausible
        // class names in best (table_off, name_off) combo for that image).
        // Pick the highest-scoring image -- avoids the "wrong Assembly-CSharp
        // duplicate" trap where Mono has multiple matches but only one has the
        // real class_cache.
        int foundImageOff = -1;
        int bestImgScore  = -1;
        long bestImgAddr  = 0;
        int  bestImgNameOff = -1;
        int[] imgNameOffs = new int[] { 0x04, 0x08, 0x0C, 0x10, 0x14, 0x18, 0x1C, 0x20 };
        // Strict class-name validator (same as the main class_cache scan -- can't
        // share a closure because looksLikeClassName is defined later in the
        // function). Inlined here to match scoring exactly.
        Func<string, bool> isClassNameish = (s) => {
            if (s == null) return false;
            int n = s.Length;
            if (n < 3 || n > 60) return false;
            char c0 = s[0];
            if (!((c0 >= 'A' && c0 <= 'Z') || (c0 >= 'a' && c0 <= 'z') || c0 == '_' || c0 == '$')) return false;
            for (int k = 1; k < n; k++) {
                char c = s[k];
                bool ok =
                    (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
                    (c >= '0' && c <= '9') ||
                    c == '_' || c == '.' || c == '$' || c == '<' || c == '>' ||
                    c == '`' || c == ' ' || c == '[' || c == ']' || c == ',';
                if (!ok) return false;
            }
            return true;
        };
        // Helper to score an image candidate by class_cache population.
        Func<long, int> scoreImageByCache = (img) => {
            int best = 0;
            for (int io = 0x80; io <= 0x600; io += 4) {
                long tbl;
                try { tbl = (long)(uint)proc.ReadValue<int>((IntPtr)(img + io)); } catch { continue; }
                if (!looksLikeHeap(tbl)) continue;
                int[] cnoCheck = new int[] { 0x10, 0x14, 0x18, 0x1C, 0x20, 0x24, 0x28, 0x2C, 0x30 };
                foreach (int cno in cnoCheck) {
                    int hits = 0;
                    for (int b = 0; b < 32; b++) {
                        long bk;
                        try { bk = (long)(uint)proc.ReadValue<int>((IntPtr)(tbl + b*4)); } catch { break; }
                        if (!looksLikeHeap(bk)) continue;
                        long np;
                        try { np = (long)(uint)proc.ReadValue<int>((IntPtr)(bk + cno)); } catch { continue; }
                        if (!looksLikeHeap(np)) continue;
                        string s2 = tryReadAsCStr(np);
                        if (isClassNameish(s2)) hits++;
                    }
                    if (hits > best) best = hits;
                }
            }
            return best;
        };
        for (int iOff = 0x40; iOff <= 0x80; iOff += 4) {
            long candImg;
            try { candImg = (long)(uint)proc.ReadValue<int>((IntPtr)(asmForImageProbe + iOff)); } catch { continue; }
            if (!looksLikeHeap(candImg)) continue;
            foreach (int inOff in imgNameOffs) {
                long inPtr;
                try { inPtr = (long)(uint)proc.ReadValue<int>((IntPtr)(candImg + inOff)); } catch { continue; }
                if (!looksLikeHeap(inPtr)) continue;
                string s = tryReadAsCStr(inPtr);
                if (s != "Assembly-CSharp") continue;
                int score = scoreImageByCache(candImg);
                logOnce("imgCand:" + iOff + ":" + inOff,
                    "  image candidate: asm+0x" + iOff.ToString("X")
                    + " img=0x" + candImg.ToString("X")
                    + " name@+0x" + inOff.ToString("X")
                    + " class_cache score=" + score);
                if (score > bestImgScore) {
                    bestImgScore   = score;
                    foundImageOff  = iOff;
                    bestImgNameOff = inOff;
                    bestImgAddr    = candImg;
                }
            }
        }
        if (bestImgAddr == 0) { log("Could not locate any MonoImage named Assembly-CSharp"); return false; }
        // Refuse to lock in an image with empty class_cache (sparse won't validate
        // downstream anyway; retry next pass when more classes have loaded).
        if (bestImgScore < 5) {
            logOnce("imgWaitForCache",
                "All Assembly-CSharp image candidates have empty class_cache (best score="
                + bestImgScore + "). Waiting for classes to load. "
                + "Best candidate so far: asm+0x" + foundImageOff.ToString("X")
                + " image=0x" + bestImgAddr.ToString("X"));
            // ONE-SHOT image bytes dump for inspection.
            try {
                byte[] ibuf = proc.ReadBytes((IntPtr)bestImgAddr, 0x600);
                if (ibuf != null) {
                    logOnce("imgDumpHdr", "Image bytes for 0x" + bestImgAddr.ToString("X") + " (0x000-0x600):");
                    for (int i = 0; i + 16 <= ibuf.Length; i += 16) {
                        uint v0 = BitConverter.ToUInt32(ibuf, i);
                        uint v1 = BitConverter.ToUInt32(ibuf, i+4);
                        uint v2 = BitConverter.ToUInt32(ibuf, i+8);
                        uint v3 = BitConverter.ToUInt32(ibuf, i+12);
                        logOnce("imgDump:" + i, "  +0x" + i.ToString("X3") + ": "
                            + v0.ToString("X8") + " " + v1.ToString("X8")
                            + " " + v2.ToString("X8") + " " + v3.ToString("X8"));
                    }
                }
            } catch {}
            return false;
        }
        imageAddr        = bestImgAddr;
        vars.O_Image_Name = bestImgNameOff;
        vars.O_Assembly_Image = foundImageOff;
        logOnce("asmImg", "AUTO-DISCOVERED: assembly.image @ +0x" + foundImageOff.ToString("X")
            + ", image.name @ +0x" + bestImgNameOff.ToString("X")
            + " (chose candidate with class_cache score=" + bestImgScore + ")");
        logOnce("acImg", "Assembly-CSharp image @ 0x" + imageAddr.ToString("X"));

        // --- AUTO-DISCOVER class_cache table + class.name offsets ---
        // For each (iOff in MonoImage, cnOff in MonoClass) pair, count how many
        // of the first 64 buckets dereference to an object whose +cnOff field
        // points to a "looks like a class name" string. The pair with the most
        // hits wins. Structural -- doesn't depend on any specific KT class
        // being loaded yet, so it works on the very first init attempt.
        var wanted = new HashSet<string> {
            "Master", "GameMaster", "GameStats", "GameHelper",
            "LevelEventMonitor", "Global"
        };
        int[] classNameOffCandidates = new int[] {
            0x10, 0x14, 0x18, 0x1C, 0x20, 0x24, 0x28, 0x2C, 0x30, 0x34, 0x38, 0x3C, 0x40, 0x44, 0x48
        };

        // "Plausible class name": 3..60 chars, printable ASCII, first char is
        // [_$A-Za-z], remaining chars in [_$.<>A-Za-z0-9` ]. The `<>` and `$`
        // allow Mono's mangled / synthetic types like "$ArrayType$32".
        Func<string, bool> looksLikeClassName = (s) => {
            if (s == null) return false;
            int n = s.Length;
            if (n < 3 || n > 60) return false;
            char c0 = s[0];
            if (!((c0 >= 'A' && c0 <= 'Z') || (c0 >= 'a' && c0 <= 'z') || c0 == '_' || c0 == '$')) return false;
            for (int k = 1; k < n; k++) {
                char c = s[k];
                bool ok =
                    (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
                    (c >= '0' && c <= '9') ||
                    c == '_' || c == '.' || c == '$' || c == '<' || c == '>' ||
                    c == '`' || c == ' ' || c == '[' || c == ']' || c == ',';
                if (!ok) return false;
            }
            return true;
        };

        int  foundTableOff     = -1;
        int  foundClassNameOff = -1;
        long foundTablePtr     = 0;
        int  foundBucketHits   = 0;
        string foundFirstClass = null;
        // Cache check: if we've already discovered these offsets, validate quickly
        // by reading the bucket array at the cached table offset and counting
        // populated buckets. If still populated, reuse cached values (much faster
        // AND avoids picking a different table when memory shifts).
        if (((IDictionary<string,object>)vars).ContainsKey("CachedTableOff")) {
            int    cachedTableOff = (int)vars.CachedTableOff;
            int    cachedNameOff  = (int)vars.CachedClassNameOff;
            long   cachedTablePtr;
            try { cachedTablePtr = (long)(uint)proc.ReadValue<int>((IntPtr)(imageAddr + cachedTableOff)); }
            catch { cachedTablePtr = 0; }
            if (looksLikeHeap(cachedTablePtr)) {
                int populated = 0;
                for (int b = 0; b < 32; b++) {
                    long bp;
                    try { bp = (long)(uint)proc.ReadValue<int>((IntPtr)(cachedTablePtr + b*4)); } catch { break; }
                    if (looksLikeHeap(bp)) populated++;
                }
                if (populated >= 4) {
                    foundTableOff     = cachedTableOff;
                    foundClassNameOff = cachedNameOff;
                    foundTablePtr     = cachedTablePtr;
                    foundBucketHits   = -1; // sentinel: used cache
                    foundFirstClass   = "[cached]";
                }
            }
        }
        // No early exit -- scan ALL iOffs and pick the highest-scoring (table, name)
        // combo. Stopping at first hit caused us to lock onto a near-empty bucket
        // (img+0xD0, 1 hit) and skip the real class_cache (img+0x2B4, 24+ hits).
        for (int iOff = 0x80; iOff <= 0x600; iOff += 4) {
            long table;
            try { table = (long)(uint)proc.ReadValue<int>((IntPtr)(imageAddr + iOff)); } catch { continue; }
            if (!looksLikeHeap(table)) continue;

            foreach (int cnOff in classNameOffCandidates) {
                int hits = 0;
                string firstName = null;
                for (int b = 0; b < 64; b++) {
                    long bucket;
                    try { bucket = (long)(uint)proc.ReadValue<int>((IntPtr)(table + b*4)); } catch { break; }
                    if (!looksLikeHeap(bucket)) continue;
                    long nmPtr;
                    try { nmPtr = (long)(uint)proc.ReadValue<int>((IntPtr)(bucket + cnOff)); } catch { continue; }
                    if (!looksLikeHeap(nmPtr)) continue;
                    string s = tryReadAsCStr(nmPtr);
                    if (looksLikeClassName(s)) {
                        hits++;
                        if (firstName == null) firstName = s;
                    }
                }
                if (hits > foundBucketHits) {
                    foundTableOff     = iOff;
                    foundClassNameOff = cnOff;
                    foundTablePtr     = table;
                    foundBucketHits   = hits;
                    foundFirstClass   = firstName;
                }
            }
        }

        // Need at least ~5 plausible class names at the same offset combo to
        // be confident. Fewer than that and we're matching noise.
        const int kClassCacheMinHits = 5;
        if (foundBucketHits < kClassCacheMinHits) {
            logOnce("classCacheLowHits", "class_cache structural scan: best (img+0x"
                + (foundTableOff >= 0 ? foundTableOff.ToString("X") : "?")
                + ", cls+0x" + (foundClassNameOff >= 0 ? foundClassNameOff.ToString("X") : "?")
                + ") had only " + foundBucketHits + " plausible names (need "
                + kClassCacheMinHits + "). "
                + "Game probably hasn't loaded enough user classes yet -- "
                + "Assembly-CSharp class_cache is empty/sparse. "
                + "Get into actual gameplay (launch knight into tower) to load classes.");
            // No exploratory spam every tick -- only after many failed attempts.
            if ((int)vars.InitTries >= 60 && (int)vars.InitTries % 60 == 0) {
                log("  exploratory dump of plausible strings reachable from MonoImage:");
                int printed = 0;
                for (int iOff = 0x80; iOff <= 0x600 && printed < 40; iOff += 4) {
                    long table;
                    try { table = (long)(uint)proc.ReadValue<int>((IntPtr)(imageAddr + iOff)); } catch { continue; }
                    if (!looksLikeHeap(table)) continue;
                    int seenHere = 0;
                    for (int b = 0; b < 16 && seenHere < 2; b++) {
                        long bucket;
                        try { bucket = (long)(uint)proc.ReadValue<int>((IntPtr)(table + b*4)); } catch { break; }
                        if (!looksLikeHeap(bucket)) continue;
                        foreach (int cnOff in classNameOffCandidates) {
                            long nmPtr;
                            try { nmPtr = (long)(uint)proc.ReadValue<int>((IntPtr)(bucket + cnOff)); } catch { continue; }
                            if (!looksLikeHeap(nmPtr)) continue;
                            string s = tryReadAsCStr(nmPtr);
                            if (looksLikeClassName(s)) {
                                log("    img+0x" + iOff.ToString("X3") + " buck[" + b + "] cls+0x" + cnOff.ToString("X2") + " -> \"" + s + "\"");
                                printed++; seenHere++;
                                if (seenHere >= 2 || printed >= 40) break;
                            }
                        }
                    }
                }
            }
            return false;
        }

        // Cache successful discovery (skip if we used the cache to find these).
        if (foundBucketHits >= 0) {
            vars.CachedTableOff     = foundTableOff;
            vars.CachedClassNameOff = foundClassNameOff;
        }
        logOnce("classCache", "AUTO-DISCOVERED: class_cache table @ img+0x" + foundTableOff.ToString("X")
            + ", class.name @ +0x" + foundClassNameOff.ToString("X")
            + " (" + foundBucketHits + " plausible class names in first 64 buckets, e.g. \""
            + foundFirstClass + "\")");

        // Find bucket count by probing int slots near the table ptr; pick the
        // first plausible bucket count where >=25% of first 64 buckets are
        // heap pointers (rules out random ints).
        int bucketCount = -1;
        string bucketSrc = null;
        for (int delta = -0x18; delta <= 0x20; delta += 4) {
            int cand;
            try { cand = proc.ReadValue<int>((IntPtr)(imageAddr + foundTableOff + delta)); } catch { continue; }
            if (cand < 11 || cand > 1000000) continue;
            int sampleN = Math.Min(cand, 64);
            int populated = 0;
            for (int i = 0; i < sampleN; i++) {
                long b;
                try { b = (long)(uint)proc.ReadValue<int>((IntPtr)(foundTablePtr + i*4)); } catch { break; }
                if (looksLikeHeap(b)) populated++;
            }
            if (populated * 4 >= sampleN) {
                bucketCount = cand;
                bucketSrc   = "table" + (delta >= 0 ? "+" : "") + "0x" + delta.ToString("X");
                break;
            }
        }
        if (bucketCount < 0) {
            log("Could not find bucket count near table ptr; aborting.");
            return false;
        }

        // Cache: if we previously found a chain offset that still yields distinct
        // names from this bucket array, reuse it. Skips the expensive brute force.
        int chainOff = -1, chainScore = 0;
        int chainOff2 = -1, chainScore2 = 0;
        if (((IDictionary<string,object>)vars).ContainsKey("CachedChainOff")) {
            int co = (int)vars.CachedChainOff;
            var seenNames = new HashSet<string>();
            int sampleN = Math.Min(bucketCount, 64);
            for (int b = 0; b < sampleN; b++) {
                long cls;
                try { cls = (long)(uint)proc.ReadValue<int>((IntPtr)(foundTablePtr + b*4)); } catch { continue; }
                if (!looksLikeHeap(cls)) continue;
                var seenPtrs = new HashSet<long>();
                int depth = 0;
                while (looksLikeHeap(cls) && depth++ < 32 && !seenPtrs.Contains(cls)) {
                    seenPtrs.Add(cls);
                    long nmPtr;
                    try { nmPtr = (long)(uint)proc.ReadValue<int>((IntPtr)(cls + foundClassNameOff)); } catch { break; }
                    if (!looksLikeHeap(nmPtr)) break;
                    string nm = tryReadAsCStr(nmPtr);
                    if (!looksLikeClassName(nm)) break;
                    seenNames.Add(nm);
                    try { cls = (long)(uint)proc.ReadValue<int>((IntPtr)(cls + co)); } catch { break; }
                }
            }
            if (seenNames.Count >= 16) {
                chainOff = co; chainScore = seenNames.Count;
                logOnce("chainCacheHit", "  chain offset cached: +0x" + co.ToString("X") + " (revalidated, " + seenNames.Count + " distinct names)");
            }
        }

        // Brute-force chain offset: try every multiple-of-4 in [0x10, 0x300]
        // as a candidate within-MonoClass byte offset. Score each by the
        // number of DISTINCT plausible class names reached by walking chains
        // from all sample buckets.
        //
        // The correct next_class_in_cache offset produces LINEAR chains
        // (each class visited at most once), so distinct count == total visits.
        // Wrong offsets like `parent` produce GRAPH-LIKE walks: many bucket
        // heads converge to the same ancestors (Object, ValueType, etc.), so
        // distinct count << total visits. Distinctness is the discriminator.
        int sampleBuckets = Math.Min(bucketCount, 64);
        // chainOff/chainScore declared above (from cache check); only brute-force
        // if cache miss.
        if (chainOff < 0)
        for (int co = 0x10; co <= 0x300; co += 4) {
            var distinctReached = new HashSet<string>();
            for (int b = 0; b < sampleBuckets; b++) {
                long cls;
                try { cls = (long)(uint)proc.ReadValue<int>((IntPtr)(foundTablePtr + b*4)); } catch { continue; }
                if (!looksLikeHeap(cls)) continue;
                var seenPtrs = new HashSet<long>();
                int depth = 0;
                while (looksLikeHeap(cls) && depth++ < 32 && !seenPtrs.Contains(cls)) {
                    seenPtrs.Add(cls);
                    long nmPtr;
                    try { nmPtr = (long)(uint)proc.ReadValue<int>((IntPtr)(cls + foundClassNameOff)); } catch { break; }
                    if (!looksLikeHeap(nmPtr)) break;
                    string nm = tryReadAsCStr(nmPtr);
                    if (!looksLikeClassName(nm)) break;
                    distinctReached.Add(nm);
                    try { cls = (long)(uint)proc.ReadValue<int>((IntPtr)(cls + co)); } catch { break; }
                }
            }
            int score = distinctReached.Count;
            if (score > chainScore) {
                chainScore2 = chainScore; chainOff2 = chainOff;
                chainScore = score; chainOff = co;
            } else if (score > chainScore2) {
                chainScore2 = score; chainOff2 = co;
            }
        }
        // Threshold: 16 distinct names is enough to distinguish a real chain offset
        // from a wrong one in the worst case. Cache might be sparse early in init.
        if (chainOff < 0 || chainScore < 16) {
            logOnce("chainFail", "Chain offset brute-force failed: best=0x"
                + (chainOff >= 0 ? chainOff.ToString("X") : "?")
                + " distinct=" + chainScore + ", 2nd=0x"
                + (chainOff2 >= 0 ? chainOff2.ToString("X") : "?")
                + " distinct=" + chainScore2
                + " (need >=16; cache likely sparse, will retry)");
            return false;
        }
        vars.CachedChainOff = chainOff;
        logOnce("ihtChain", "  bucket count = " + bucketCount + " (" + bucketSrc + ")"
            + ", chain offset = +0x" + chainOff.ToString("X")
            + " (distinct=" + chainScore
            + ", 2nd=0x" + (chainOff2 >= 0 ? chainOff2.ToString("X") : "?")
            + " distinct=" + chainScore2 + ")");

        vars.Image_ClassCache_TableAbs = imageAddr + foundTableOff;
        vars.O_Class_Name             = foundClassNameOff;
        vars.O_IHT_NextClassSlot      = chainOff;
        long bucketArr = foundTablePtr;

        // --- find every class we need by name (single pass, walks chains) ---
        var classes = new Dictionary<string, long>();
        int totalClassesSeen = 0;
        // Diagnostic: collect distinct names so we can see what we're walking.
        var distinctNames = new HashSet<string>();
        var firstNames = new List<string>(); // walk-order, first 30 distinct
        int gamePrefixCount = 0;
        for (int b = 0; b < bucketCount; b++) {
            long cls;
            try { cls = (long)(uint)proc.ReadValue<int>((IntPtr)(bucketArr + b*4)); } catch { continue; }
            var seenInChain = new HashSet<long>();
            int guard = 0;
            while (looksLikeHeap(cls) && guard++ < 4096 && !seenInChain.Contains(cls)) {
                seenInChain.Add(cls);
                long nmPtr;
                try { nmPtr = (long)(uint)proc.ReadValue<int>((IntPtr)(cls + foundClassNameOff)); } catch { break; }
                if (looksLikeHeap(nmPtr)) {
                    string nm = tryReadAsCStr(nmPtr);
                    if (looksLikeClassName(nm)) {
                        totalClassesSeen++;
                        if (distinctNames.Add(nm)) {
                            if (firstNames.Count < 30) firstNames.Add(nm);
                            if (nm.StartsWith("Game")) gamePrefixCount++;
                        }
                        if (wanted.Contains(nm) && !classes.ContainsKey(nm)) {
                            classes[nm] = cls;
                            logOnce("cls:" + nm, "  found class " + nm + " @ 0x" + cls.ToString("X"));
                        }
                    }
                }
                try { cls = (long)(uint)proc.ReadValue<int>((IntPtr)(cls + chainOff)); } catch { break; }
            }
            if (classes.Count == wanted.Count) break;
        }
        var missing = new List<string>();
        foreach (var n in wanted) if (!classes.ContainsKey(n)) missing.Add(n);
        if (missing.Count > 0) {
            logOnce("waitingClasses", "  waiting on " + missing.Count + " classes: " + string.Join(",", missing.ToArray())
                + " (" + totalClassesSeen + " visits, " + distinctNames.Count + " distinct, "
                + gamePrefixCount + " Game*)");
            logOnce("first30", "  first 30 distinct: " + string.Join(",", firstNames.ToArray()));
            return false;
        }

        // --- field lookup helpers ---
        Func<long, string, int> fieldOffset = (clsPtr, fieldName) => {
            long fields = (long)(uint)proc.ReadValue<int>((IntPtr)(clsPtr + (int)vars.O_Class_Fields));
            int count = proc.ReadValue<int>((IntPtr)(clsPtr + (int)vars.O_Class_FieldCount));
            if (fields == 0 || count <= 0 || count > 4096) {
                logOnce("fieldBad:" + fieldName, "  fieldOffset(" + fieldName + ") on cls@0x" + clsPtr.ToString("X")
                    + ": bad fields=0x" + fields.ToString("X") + " count=" + count);
                return -1;
            }
            var seenNames = new List<string>();
            for (int i = 0; i < count; i++) {
                long fPtr  = fields + i * (int)vars.O_Field_Size;
                long fnPtr = (long)(uint)proc.ReadValue<int>((IntPtr)(fPtr + (int)vars.O_Field_Name));
                string fn  = rcstr(proc, (IntPtr)fnPtr);
                if (fn != null && seenNames.Count < 20) seenNames.Add(fn);
                if (fn == fieldName) {
                    return proc.ReadValue<int>((IntPtr)(fPtr + (int)vars.O_Field_Offset));
                }
            }
            logOnce("fieldMiss:" + fieldName, "  fieldOffset(" + fieldName + ") not found in " + count
                + " fields of cls@0x" + clsPtr.ToString("X") + " -- saw: " + string.Join(",", seenNames.ToArray()));
            return -1;
        };

        Func<long, long> staticBase = (clsPtr) => {
            long rti = (long)(uint)proc.ReadValue<int>((IntPtr)(clsPtr + (int)vars.O_Class_RuntimeInfo));
            if (rti == 0) return 0L;
            long vtbl = (long)(uint)proc.ReadValue<int>((IntPtr)(rti + (int)vars.O_RTInfo_VTables));
            if (vtbl == 0) return 0L;
            int vtSize = proc.ReadValue<int>((IntPtr)(clsPtr + (int)vars.O_Class_VTableSize));
            return vtbl + (int)vars.O_VTable_HeaderEnd + vtSize;
        };

        // --- auto-discover MonoClass.fields and MonoClass.field.count ---
        // The hardcoded O_Class_Fields (0x60) and O_Class_FieldCount (0xF8)
        // values vary across Mono builds. Use Master's known static fields as
        // ground truth: for each (fieldsOff, countOff) candidate combo,
        // interpret the data as a MonoClassField array and count how many
        // known Master field names appear at +O_Field_Name. Combo with the
        // most matches wins.
        var knownMasterFields = new HashSet<string> {
            "started", "global", "minX", "maxX", "_stats", "_caller", "ratio", "stats"
        };
        long masterCls = classes["Master"];
        int bestCF = -1, bestCN = -1, bestMatches = 0, bestCount = 0;
        for (int cf = 0x40; cf <= 0xE0; cf += 4) {
            long fieldsPtr;
            try { fieldsPtr = (long)(uint)proc.ReadValue<int>((IntPtr)(masterCls + cf)); } catch { continue; }
            if (!looksLikeHeap(fieldsPtr)) continue;
            for (int cn = 0x60; cn <= 0x150; cn += 4) {
                if (cn == cf) continue;
                int count;
                try { count = proc.ReadValue<int>((IntPtr)(masterCls + cn)); } catch { continue; }
                if (count < 1 || count > 50) continue;
                int matches = 0;
                for (int i = 0; i < count; i++) {
                    long fPtr = fieldsPtr + i * (int)vars.O_Field_Size;
                    long namePtr;
                    try { namePtr = (long)(uint)proc.ReadValue<int>((IntPtr)(fPtr + (int)vars.O_Field_Name)); } catch { break; }
                    if (!looksLikeHeap(namePtr)) continue;
                    string fnm = tryReadAsCStr(namePtr);
                    if (fnm != null && knownMasterFields.Contains(fnm)) matches++;
                }
                if (matches > bestMatches) {
                    bestMatches = matches; bestCF = cf; bestCN = cn; bestCount = count;
                }
            }
        }
        if (bestMatches < 3) {
            logOnce("classFieldsFail", "Could not auto-discover Class.fields layout: best " + bestMatches
                + " known Master fields found at fields@+0x"
                + (bestCF >= 0 ? bestCF.ToString("X") : "?")
                + ", count@+0x" + (bestCN >= 0 ? bestCN.ToString("X") : "?")
                + " (Master's MonoClass.fields likely not yet populated; needs Master.stats or similar to be accessed by game code)");
            return false;
        }
        logOnce("classFields", "  AUTO-DISCOVERED Class.fields @ +0x" + bestCF.ToString("X")
            + ", Class.fieldCount @ +0x" + bestCN.ToString("X")
            + " (Master has " + bestCount + " fields, " + bestMatches + " known matches)");
        vars.O_Class_Fields     = bestCF;
        vars.O_Class_FieldCount = bestCN;

        // --- auto-discover MonoVTable static-data layout (RuntimeInfo etc.) ---
        // Static-field base = MonoVTable + headerEnd + vtableMethodsBytes,
        // where MonoVTable lives at RuntimeInfo.domain_vtables[0]. Four
        // hardcoded offsets to brute-force: O_Class_RuntimeInfo,
        // O_RTInfo_VTables, O_Class_VTableSize, O_VTable_HeaderEnd. Plus the
        // unit of VTableSize (bytes vs count-of-4-byte-pointers).
        //
        // Validation uses Master's known field layout. Once gameplay has
        // started, Master._stats and Master._caller are both heap pointers
        // (Master.start() populates them). Master.started is a bool, 0 or 1.
        // Score: +2 for heap _stats, +2 for heap _caller, +1 each for 0/1
        // for started. Higher score = more confident.
        // Walk Master's fields to find offsets we'll use for validation
        int sFOff = -1, cFOff = -1, stFOff = -1, glFOff = -1;
        {
            long fpa = (long)(uint)proc.ReadValue<int>((IntPtr)(masterCls + bestCF));
            for (int i = 0; i < bestCount; i++) {
                long fPtr = fpa + i * (int)vars.O_Field_Size;
                long namePtr;
                try { namePtr = (long)(uint)proc.ReadValue<int>((IntPtr)(fPtr + (int)vars.O_Field_Name)); } catch { continue; }
                if (!looksLikeHeap(namePtr)) continue;
                string fnm = tryReadAsCStr(namePtr);
                if (fnm == null) continue;
                int fOff;
                try { fOff = proc.ReadValue<int>((IntPtr)(fPtr + (int)vars.O_Field_Offset)); } catch { continue; }
                if (fnm == "_stats")  sFOff = fOff;
                else if (fnm == "_caller") cFOff = fOff;
                else if (fnm == "started") stFOff = fOff;
                else if (fnm == "global")  glFOff = fOff;
            }
        }
        if (sFOff < 0 || stFOff < 0) {
            log("Could not locate Master._stats / Master.started field offsets; aborting.");
            return false;
        }

        // Also walk Global's fields for cross-class validation. Global has
        // bool finishedBoss and bool infiniteMode -- both must read as 0 or 1
        // when our static-base formula is correct, and (unless the user toggled
        // infinite mode or beat the game) both are expected to be 0.
        long globalCls = classes["Global"];
        int gFbOff = -1, gImOff = -1;
        {
            long gFp;
            int gCnt;
            try {
                gFp  = (long)(uint)proc.ReadValue<int>((IntPtr)(globalCls + bestCF));
                gCnt = proc.ReadValue<int>((IntPtr)(globalCls + bestCN));
            } catch { gFp = 0; gCnt = 0; }
            if (gFp != 0 && gCnt > 0 && gCnt < 200) {
                for (int i = 0; i < gCnt; i++) {
                    long fPtr = gFp + i * (int)vars.O_Field_Size;
                    long namePtr;
                    try { namePtr = (long)(uint)proc.ReadValue<int>((IntPtr)(fPtr + (int)vars.O_Field_Name)); } catch { continue; }
                    if (!looksLikeHeap(namePtr)) continue;
                    string fnm = tryReadAsCStr(namePtr);
                    if (fnm == null) continue;
                    int fOff;
                    try { fOff = proc.ReadValue<int>((IntPtr)(fPtr + (int)vars.O_Field_Offset)); } catch { continue; }
                    if (fnm == "finishedBoss") gFbOff = fOff;
                    else if (fnm == "infiniteMode") gImOff = fOff;
                }
            }
        }
        if (gFbOff < 0 || gImOff < 0) {
            logOnce("globalFieldsMissing", "  Global field offsets not yet available (finishedBoss=" + gFbOff
                + ", infiniteMode=" + gImOff + "); waiting for Global.fields to populate.");
            return false;
        }

        // Walk GameMaster fields to find helper offset (for cross-class static-base validation).
        long gmCls = classes["GameMaster"];
        int gmHelperOff = -1;
        {
            long gmFp;
            int gmCnt;
            try {
                gmFp  = (long)(uint)proc.ReadValue<int>((IntPtr)(gmCls + bestCF));
                gmCnt = proc.ReadValue<int>((IntPtr)(gmCls + bestCN));
            } catch { gmFp = 0; gmCnt = 0; }
            if (gmFp != 0 && gmCnt > 0 && gmCnt < 200) {
                for (int i = 0; i < gmCnt; i++) {
                    long fPtr = gmFp + i * (int)vars.O_Field_Size;
                    long namePtr;
                    try { namePtr = (long)(uint)proc.ReadValue<int>((IntPtr)(fPtr + (int)vars.O_Field_Name)); } catch { continue; }
                    if (!looksLikeHeap(namePtr)) continue;
                    string fnm = tryReadAsCStr(namePtr);
                    if (fnm == "helper") {
                        try { gmHelperOff = proc.ReadValue<int>((IntPtr)(fPtr + (int)vars.O_Field_Offset)); } catch {}
                        break;
                    }
                }
            }
        }
        if (gmHelperOff < 0) {
            logOnce("gmHelperMissing", "  GameMaster.helper field offset not yet available; waiting for GameMaster.fields to populate.");
            return false;
        }
        // Helper: validate a pointer dereferences to MonoObject -> vtable -> class -> name == expectedClassName.
        Func<long, string, bool> derefValidates = (objPtr, expectedClassName) => {
            if (objPtr == 0) return false;
            if (!looksLikeHeap(objPtr)) return false;
            long vt, cls, np;
            try {
                vt  = (long)(uint)proc.ReadValue<int>((IntPtr)objPtr);
                if (!looksLikeHeap(vt)) return false;
                cls = (long)(uint)proc.ReadValue<int>((IntPtr)vt);
                if (!looksLikeHeap(cls)) return false;
                np  = (long)(uint)proc.ReadValue<int>((IntPtr)(cls + foundClassNameOff));
                if (!looksLikeHeap(np)) return false;
            } catch { return false; }
            return tryReadAsCStr(np) == expectedClassName;
        };

        int[] heCandidates  = new int[] {
            0x10, 0x14, 0x18, 0x1C, 0x20, 0x24, 0x28, 0x2C, 0x30, 0x34, 0x38, 0x3C, 0x40, 0x44, 0x48, 0x4C, 0x50, 0x58
        };
        // CONFIRMED via byte dump: MonoClass+0xA4 is runtime_info, +0x04 within
        // runtime_info is the first domain's MonoVTable* (max_domain at +0).
        // No need to brute-force these any further.
        int[] rtvCandidates = new int[] { 0x04 };
        int   bestStaticScore = 0;
        int   bestRTI = -1, bestRTV = -1, bestVTS = -1, bestHE = -1, bestUnit = 0, bestDeref = 0;
        long  bestStaticBase = 0;
        // (helper for ptr->class.name validation lives in `derefValidates` above)

        // Helper: compute static base for a class using a candidate formula.
        // Three modes (encoded in `deref`):
        //   0 = inline: static data starts at  vt+he+vts*unit  (old Mono, no deref)
        //   1 = end-deref: static data ptr is stored at  vt+he+vts*unit
        //   2 = fixed-deref: static data ptr is at a fixed offset in MonoVTable.
        //       For mode 2, `he_` is the absolute offset, and vts/unit are ignored.
        Func<long,int,int,int,int,int,int,long> computeBase = (clsPtr, cRTI_, cRTV_, cVTS_, he_, unit_, deref_) => {
            long rti;
            try { rti = (long)(uint)proc.ReadValue<int>((IntPtr)(clsPtr + cRTI_)); } catch { return 0L; }
            if (!looksLikeHeap(rti)) return 0L;
            long vtbl;
            try { vtbl = (long)(uint)proc.ReadValue<int>((IntPtr)(rti + cRTV_)); } catch { return 0L; }
            if (!looksLikeHeap(vtbl)) return 0L;
            if (deref_ == 2) {
                // Fixed-offset pointer in MonoVTable.
                long sdata;
                try { sdata = (long)(uint)proc.ReadValue<int>((IntPtr)(vtbl + he_)); } catch { return 0L; }
                if (!looksLikeHeap(sdata)) return 0L;
                return sdata;
            }
            int vts;
            try { vts = proc.ReadValue<int>((IntPtr)(clsPtr + cVTS_)); } catch { return 0L; }
            if (vts < 0 || vts > 0x4000) return 0L;
            long endAddr = vtbl + he_ + vts * unit_;
            if (deref_ == 0) return endAddr;
            long sdata2;
            try { sdata2 = (long)(uint)proc.ReadValue<int>((IntPtr)endAddr); } catch { return 0L; }
            if (!looksLikeHeap(sdata2)) return 0L;
            return sdata2;
        };
        // Side-by-side MonoClass dump revealed:
        //   +0x064 = field_count (Master=7, GM=11)
        //   +0x06C = method_count (Master=7, GM=22) — this is vtable_size
        //   +0x074 = heap ptr that varies per class (vtable or runtime_info)
        // Narrow the search to known candidates first; brute force fills in the rest.
        int[] cVTSCandidates = new int[] { 0x6C, 0x64, 0x14, 0x10, 0x60, 0x68, 0x70, 0x78 };
        // === COMPREHENSIVE STATIC-AREA DIAGNOSTIC DUMP ===
        // For Master, GameMaster, Global: walk each class's fields, dump VTable
        // header, and for each candidate `headerEnd` value interpret the bytes
        // at vt+HE+field.offset as that field's value. The correct HE gives
        // bool bytes = 0/1, ptrs heap-or-null, GameMaster.gameStats = 0.
        try {
            string[] diagClasses = new string[] { "Master", "GameMaster", "Global" };
            int[] heCandidates2 = new int[] { 0x18, 0x1C, 0x20, 0x24, 0x28, 0x2C, 0x30, 0x34, 0x38, 0x3C, 0x40, 0x44, 0x48, 0x4C, 0x50 };
            foreach (string clsName in diagClasses) {
                if (!classes.ContainsKey(clsName)) {
                    logOnce("diag:" + clsName + ":notfound", "=== DIAG " + clsName + ": not in class_cache ===");
                    continue;
                }
                long clsPtr = classes[clsName];
                long rti = 0, vt = 0;
                try { rti = (long)(uint)proc.ReadValue<int>((IntPtr)(clsPtr + 0xA4)); } catch {}
                if (rti != 0) try { vt = (long)(uint)proc.ReadValue<int>((IntPtr)(rti + 0x4)); } catch {}
                logOnce("diag:" + clsName + ":hdr", "=== DIAG " + clsName + " (cls=0x" + clsPtr.ToString("X")
                    + " rti=0x" + rti.ToString("X") + " vt=0x" + vt.ToString("X") + ") ===");
                if (vt == 0) {
                    logOnce("diag:" + clsName + ":novt", "  VTable not yet allocated; class needs to be USED by game code.");
                    continue;
                }
                // Walk class fields, build list of (name, offset).
                long fp = 0; int fc = 0;
                try { fp = (long)(uint)proc.ReadValue<int>((IntPtr)(clsPtr + (int)vars.O_Class_Fields)); } catch {}
                try { fc = proc.ReadValue<int>((IntPtr)(clsPtr + (int)vars.O_Class_FieldCount)); } catch {}
                var diagFields = new List<KeyValuePair<string,int>>();
                if (fp != 0 && fc > 0 && fc < 100) {
                    for (int i = 0; i < fc; i++) {
                        long fPtr = fp + i * (int)vars.O_Field_Size;
                        long namePtr; int foff;
                        try { namePtr = (long)(uint)proc.ReadValue<int>((IntPtr)(fPtr + (int)vars.O_Field_Name)); } catch { continue; }
                        try { foff    = proc.ReadValue<int>((IntPtr)(fPtr + (int)vars.O_Field_Offset)); } catch { continue; }
                        string fname = tryReadAsCStr(namePtr);
                        if (fname == null) continue;
                        diagFields.Add(new KeyValuePair<string,int>(fname, foff));
                    }
                }
                logOnce("diag:" + clsName + ":fields", "  Fields (" + diagFields.Count + "): "
                    + string.Join(", ", diagFields.ConvertAll(f => f.Key + "@0x" + f.Value.ToString("X")).ToArray()));
                // Dump VTable bytes 0x00 to 0x80
                byte[] vtBuf = null;
                try { vtBuf = proc.ReadBytes((IntPtr)vt, 0x80); } catch {}
                if (vtBuf != null) {
                    for (int i = 0; i + 4 <= vtBuf.Length; i += 4) {
                        uint v = BitConverter.ToUInt32(vtBuf, i);
                        logOnce("diag:" + clsName + ":vt:" + i, "    vt+0x" + i.ToString("X2") + " = 0x" + v.ToString("X8"));
                    }
                }
                // For each candidate HE, interpret the bytes at vt+HE+field.offset
                // as that field's value. Show as both int and byte.
                foreach (int he in heCandidates2) {
                    var sb = new System.Text.StringBuilder();
                    sb.Append("  HE=0x" + he.ToString("X") + ": ");
                    int n = 0;
                    foreach (var f in diagFields) {
                        long addr = vt + he + f.Value;
                        uint v;
                        try { v = (uint)proc.ReadValue<int>((IntPtr)addr); } catch { continue; }
                        if (n > 0) sb.Append(", ");
                        sb.Append(f.Key + "=0x" + v.ToString("X8"));
                        n++;
                        if (n >= 8) { sb.Append(", ..."); break; }
                    }
                    logOnce("diag:" + clsName + ":he:" + he, sb.ToString());
                }
            }
        } catch {}

        // CONFIRMED via byte dump: runtime_info is at MonoClass+0xA4.
        for (int cRTI = 0xA4; cRTI <= 0xA4; cRTI += 4) {
            foreach (int cRTV in rtvCandidates) {
                foreach (int cVTS in cVTSCandidates) {
                    foreach (int unit in new int[] { 4, 1 }) {  // standard Mono first
                        foreach (int he in heCandidates) {
                            foreach (int deref in new int[] { 0, 1, 2 }) {
                            long mSbase = computeBase(masterCls, cRTI, cRTV, cVTS, he, unit, deref);
                            if (mSbase == 0) continue;
                            long gSbase = computeBase(globalCls, cRTI, cRTV, cVTS, he, unit, deref);
                            if (gSbase == 0) continue;

                            // ---- 3 independent bool-byte checks across 2 classes ----
                            byte mStarted, gFinished, gInfinite;
                            try { mStarted  = proc.ReadValue<byte>((IntPtr)(mSbase + stFOff)); } catch { continue; }
                            try { gFinished = proc.ReadValue<byte>((IntPtr)(gSbase + gFbOff)); } catch { continue; }
                            try { gInfinite = proc.ReadValue<byte>((IntPtr)(gSbase + gImOff)); } catch { continue; }
                            if (mStarted  != 0 && mStarted  != 1) continue;
                            if (gFinished != 0 && gFinished != 1) continue;
                            if (gInfinite != 0 && gInfinite != 1) continue;

                            // ---- Validate Master._stats: heap-or-null; if non-null, must deref to GameStats ----
                            long statsVal;
                            try { statsVal = (long)(uint)proc.ReadValue<int>((IntPtr)(mSbase + sFOff)); } catch { continue; }
                            if (statsVal != 0) {
                                if (!looksLikeHeap(statsVal)) continue;
                                if (!derefValidates(statsVal, "GameStats")) continue;
                            }

                            // ---- HARD: GameMaster.gameStats must be 0 (never assigned in source) ----
                            long gmGameStats;
                            long gmSbase0 = computeBase(gmCls, cRTI, cRTV, cVTS, he, unit, deref);
                            if (gmSbase0 == 0) continue;
                            // Find gameStats field offset in GameMaster
                            int gmGameStatsOff = -1;
                            {
                                long gmFp2;
                                int  gmCnt2;
                                try {
                                    gmFp2  = (long)(uint)proc.ReadValue<int>((IntPtr)(gmCls + bestCF));
                                    gmCnt2 = proc.ReadValue<int>((IntPtr)(gmCls + bestCN));
                                } catch { gmFp2 = 0; gmCnt2 = 0; }
                                if (gmFp2 != 0 && gmCnt2 > 0 && gmCnt2 < 100) {
                                    for (int gi = 0; gi < gmCnt2; gi++) {
                                        long gfPtr = gmFp2 + gi * (int)vars.O_Field_Size;
                                        long gnPtr;
                                        try { gnPtr = (long)(uint)proc.ReadValue<int>((IntPtr)(gfPtr + (int)vars.O_Field_Name)); } catch { continue; }
                                        if (!looksLikeHeap(gnPtr)) continue;
                                        string gnm = tryReadAsCStr(gnPtr);
                                        if (gnm == "gameStats") {
                                            try { gmGameStatsOff = proc.ReadValue<int>((IntPtr)(gfPtr + (int)vars.O_Field_Offset)); } catch {}
                                            break;
                                        }
                                    }
                                }
                            }
                            if (gmGameStatsOff < 0) continue; // can't validate without gameStats offset
                            try { gmGameStats = (long)(uint)proc.ReadValue<int>((IntPtr)(gmSbase0 + gmGameStatsOff)); } catch { continue; }
                            if (gmGameStats != 0) continue; // gameStats MUST be null

                            // ---- BONUS: GameMaster.helper deref -> GameHelper ----
                            // Strongly prefer formulas where this works, but don't
                            // require it -- helps init complete even when GameMaster's
                            // static-area layout doesn't match Master's.
                            int helperBonus = 0;
                            long gmSbase = gmSbase0; // already computed above
                            {
                                long helperVal;
                                try {
                                    helperVal = (long)(uint)proc.ReadValue<int>((IntPtr)(gmSbase + gmHelperOff));
                                    if (derefValidates(helperVal, "GameHelper")) helperBonus = 5;
                                } catch {}
                            }

                            // Hard checks passed (3 bools + GameStats deref) = base 5.
                            int score = 5 + helperBonus;
                            long callerVal = -1, globalRefVal = -1;
                            if (cFOff >= 0) try { callerVal    = (long)(uint)proc.ReadValue<int>((IntPtr)(mSbase + cFOff)); } catch {}
                            if (glFOff >= 0) try { globalRefVal = (long)(uint)proc.ReadValue<int>((IntPtr)(mSbase + glFOff)); } catch {}
                            if (callerVal    == 0 || looksLikeHeap(callerVal))    score += 1;
                            if (globalRefVal == 0 || looksLikeHeap(globalRefVal)) score += 1;
                            if (score > bestStaticScore) {
                                bestStaticScore = score;
                                bestRTI = cRTI; bestRTV = cRTV; bestVTS = cVTS; bestHE = he; bestUnit = unit; bestDeref = deref;
                                bestStaticBase = mSbase;
                            }
                            }
                        }
                    }
                }
            }
        }
        // Score 5 = passed hard checks: 3 bool bytes + GameStats deref.
        // GameMaster.helper validation is a +5 bonus (preferred but not required).
        if (bestStaticScore < 5) {
            logOnce("staticBaseWait", "  Static-base discovery waiting for Master._stats to populate "
                + "(Master.start() runs when game accesses Master.stats -- usually as UI loads or "
                + "gameplay starts). Best score so far: " + bestStaticScore);
            // One-time diagnostic dump of Master's MonoClass bytes so we can
            // identify the correct offsets by hand if the brute-force search
            // doesn't find them. Only emits once.
            try {
                byte[] mcls = proc.ReadBytes((IntPtr)masterCls, 0x150);
                if (mcls != null) {
                    var lines = new List<string>();
                    lines.Add("MonoClass dump for Master @ 0x" + masterCls.ToString("X") + ":");
                    for (int i = 0; i + 16 <= mcls.Length; i += 16) {
                        uint v0 = BitConverter.ToUInt32(mcls, i);
                        uint v1 = BitConverter.ToUInt32(mcls, i+4);
                        uint v2 = BitConverter.ToUInt32(mcls, i+8);
                        uint v3 = BitConverter.ToUInt32(mcls, i+12);
                        lines.Add("  +0x" + i.ToString("X3") + ": " + v0.ToString("X8")
                            + " " + v1.ToString("X8") + " " + v2.ToString("X8") + " " + v3.ToString("X8"));
                    }
                    logOnce("masterDump", string.Join("\n", lines.ToArray()));
                }
            } catch {}
            log("Static-base brute force inconclusive: best score " + bestStaticScore
                + " at RTI@+0x" + (bestRTI >= 0 ? bestRTI.ToString("X") : "?")
                + " RTV@+0x" + (bestRTV >= 0 ? bestRTV.ToString("X") : "?")
                + " VTS@+0x" + (bestVTS >= 0 ? bestVTS.ToString("X") : "?")
                + " HE=+0x" + (bestHE >= 0 ? bestHE.ToString("X") : "?")
                + " unit=" + bestUnit + " deref=" + bestDeref + " (need >=5)");
            return false;
        }
        logOnce("staticBase", "  AUTO-DISCOVERED RTI@+0x" + bestRTI.ToString("X")
            + " RTV@+0x" + bestRTV.ToString("X")
            + " VTS@+0x" + bestVTS.ToString("X")
            + " HE=+0x" + bestHE.ToString("X")
            + " unit=" + bestUnit + " deref=" + bestDeref
            + " (score=" + bestStaticScore + ", Master staticBase=0x" + bestStaticBase.ToString("X") + ")");
        vars.O_Class_RuntimeInfo  = bestRTI;
        vars.O_RTInfo_VTables     = bestRTV;
        vars.O_Class_VTableSize   = bestVTS;
        vars.O_VTable_HeaderEnd   = bestHE;
        vars.VTableSize_Unit      = bestUnit;
        vars.StaticBase_Deref     = bestDeref;

        // Override staticBase helper to use the discovered formula.
        staticBase = (clsPtr) => {
            long rti = (long)(uint)proc.ReadValue<int>((IntPtr)(clsPtr + (int)vars.O_Class_RuntimeInfo));
            if (rti == 0) return 0L;
            long vtbl = (long)(uint)proc.ReadValue<int>((IntPtr)(rti + (int)vars.O_RTInfo_VTables));
            if (vtbl == 0) return 0L;
            int dmode = (int)vars.StaticBase_Deref;
            if (dmode == 2) {
                try { return (long)(uint)proc.ReadValue<int>((IntPtr)(vtbl + (int)vars.O_VTable_HeaderEnd)); } catch { return 0L; }
            }
            int vtSize = proc.ReadValue<int>((IntPtr)(clsPtr + (int)vars.O_Class_VTableSize));
            long endAddr = vtbl + (int)vars.O_VTable_HeaderEnd + vtSize * (int)vars.VTableSize_Unit;
            if (dmode == 0) return endAddr;
            try { return (long)(uint)proc.ReadValue<int>((IntPtr)endAddr); } catch { return 0L; }
        };

        // --- resolve static-field absolute addresses ---
        var dict = (IDictionary<string,object>)vars;
        Action<string, string, string> resolveStatic = (cn, fn, key) => {
            long sb = staticBase(classes[cn]);
            int off = fieldOffset(classes[cn], fn);
            if (off < 0) throw new Exception("field offset lookup failed for " + cn + "." + fn);
            if (sb == 0) throw new Exception("static base address is 0 for class " + cn
                + " (off=" + off + " found ok); O_Class_RuntimeInfo/VTableSize likely wrong");
            dict[key] = sb + off;
            logOnce("static:" + key, "  &" + cn + "." + fn + " = 0x" + (sb+off).ToString("X"));
        };
        Action<string, string, string> resolveInstance = (cn, fn, key) => {
            int off = fieldOffset(classes[cn], fn);
            if (off < 0) throw new Exception("missing instance " + cn + "." + fn);
            dict[key] = off;
            logOnce("inst:" + key, "  offset " + cn + "." + fn + " = 0x" + off.ToString("X"));
        };

        try {
            // Master.stats is a C# property; the actual field is _stats.
            resolveStatic ("Master",            "_stats",         "Addr_Master_stats");
            resolveStatic ("GameMaster",        "helper",         "Addr_GameMaster_helper");
            // GameMaster.gameStats is another GameStats reference; should equal Master._stats.
            // Used as cross-check that GameMaster's static base is correctly computed.
            resolveStatic ("GameMaster",        "gameStats",      "Addr_GameMaster_gameStats");
            resolveStatic ("LevelEventMonitor", "numDoors",       "Addr_numDoors");
            resolveStatic ("Global",            "finishedBoss",   "Addr_finishedBoss");
            resolveStatic ("Global",            "infiniteMode",   "Addr_infiniteMode");

            resolveInstance("GameStats",  "finishedMissions", "Foff_finishedMissions");
            resolveInstance("GameStats",  "finishedStory",    "Foff_finishedStory");
            resolveInstance("GameStats",  "lastFloor",        "Foff_lastFloor");
            resolveInstance("GameStats",  "numdied",          "Foff_numdied");
            resolveInstance("GameHelper", "realTime",         "Foff_realTime");
            resolveInstance("GameHelper", "isInMainGameplay", "Foff_isInMainGameplay");
            resolveInstance("GameHelper", "inBoss",           "Foff_inBoss");
        } catch (Exception ex) {
            logOnce("resolFail", "resolution failed: " + ex.Message);
            return false;
        }

        // IGT accumulator state.
        vars.igtAccumTicks = 0L;
        vars.lastRealTime  = 0;
        vars.lastHelperPtr = 0L;
        return true;
    });
}

init
{
    // `settings` here is the reader -- safe to index. Pull the debug flag
    // onto vars so the Log lambda (defined in startup) can read it.
    vars.LogEnabled     = settings["debug"];
    vars.Initialized    = false;
    vars.JustInitialized = false;
    vars.LastDiagLogSec = 0.0;
    vars.InitTries      = 0;
    refreshRate         = 60;

    print("[KT] init -- version " + vars.ScriptVersion + " pid=" + game.Id);

    // Find mono.dll via ASL's wow64-safe `modules` collection. This is the
    // ONLY way to enumerate modules of a 32-bit game from a 64-bit LiveSplit;
    // `Process.Modules` will throw in that combination.
    vars.MonoBaseAddr = 0L;
    foreach (var m in modules) {
        if (m.ModuleName.Equals("mono.dll", StringComparison.OrdinalIgnoreCase)) {
            vars.MonoBaseAddr = (long)(uint)(int)m.BaseAddress;
            ((Action<object>)vars.Log)("init: mono.dll base = 0x" + ((long)vars.MonoBaseAddr).ToString("X"));
            break;
        }
    }
    if ((long)vars.MonoBaseAddr == 0)
        ((Action<object>)vars.Log)("init: mono.dll not found in module list yet");
}

update
{
    if (!vars.Initialized)
    {
        var log = (Action<object>)vars.Log;
        vars.InitTries++;

        // Throttle: refreshRate is 60Hz; only attempt init every 30 ticks
        // (~2Hz). Class loading is slow and waiting at full speed just spams
        // DebugView. mono.dll module scan still runs at full speed below.
        if ((int)vars.InitTries % 30 != 1) return false;

        // If mono.dll wasn't loaded when init ran, retry the module scan now.
        if ((long)vars.MonoBaseAddr == 0) {
            foreach (var m in modules) {
                if (m.ModuleName.Equals("mono.dll", StringComparison.OrdinalIgnoreCase)) {
                    vars.MonoBaseAddr = (long)(uint)(int)m.BaseAddress;
                    log("update: mono.dll base = 0x" + ((long)vars.MonoBaseAddr).ToString("X"));
                    break;
                }
            }
            if ((long)vars.MonoBaseAddr == 0) return false;
        }

        bool ok = false;
        try {
            ok = ((Func<Process,bool>)vars.TryInitialize)(game);
        } catch (Exception ex) {
            log("init THREW: " + ex.GetType().Name + ": " + ex.Message);
            if (vars.InitTries <= 5 && ex.StackTrace != null) {
                foreach (string line in ex.StackTrace.Split('\n'))
                    log("  " + line.Trim());
            }
            return false;
        }
        if (ok) {
            vars.Initialized = true;
            vars.JustInitialized = true;
            vars.LastDiagLogSec = 0.0;
            log("=== init complete ===");
        } else {
            return false;
        }
    }

    long aStats   = (long)vars.Addr_Master_stats;
    long aHelper  = (long)vars.Addr_GameMaster_helper;

    current.statsPtr  = (long)(uint)game.ReadValue<int>((IntPtr)aStats);
    current.helperPtr = (long)(uint)game.ReadValue<int>((IntPtr)aHelper);
    current.numDoors  = game.ReadValue<int> ((IntPtr)(long)vars.Addr_numDoors);
    current.finBoss   = game.ReadValue<bool>((IntPtr)(long)vars.Addr_finishedBoss);
    current.infMode   = game.ReadValue<bool>((IntPtr)(long)vars.Addr_infiniteMode);

    if (current.statsPtr != 0) {
        current.finMissions = game.ReadValue<bool>((IntPtr)(current.statsPtr + (int)vars.Foff_finishedMissions));
        current.finStory    = game.ReadValue<bool>((IntPtr)(current.statsPtr + (int)vars.Foff_finishedStory));
        current.lastFloor   = game.ReadValue<int> ((IntPtr)(current.statsPtr + (int)vars.Foff_lastFloor));
        current.numDied     = game.ReadValue<int> ((IntPtr)(current.statsPtr + (int)vars.Foff_numdied));
    } else {
        current.finMissions = false;
        current.finStory    = false;
        current.lastFloor   = 0;
        current.numDied     = 0;
    }

    if (current.helperPtr != 0) {
        current.realTime   = game.ReadValue<int> ((IntPtr)(current.helperPtr + (int)vars.Foff_realTime));
        current.inMainPlay = game.ReadValue<bool>((IntPtr)(current.helperPtr + (int)vars.Foff_isInMainGameplay));
        current.inBoss     = game.ReadValue<bool>((IntPtr)(current.helperPtr + (int)vars.Foff_inBoss));
    } else {
        current.realTime   = 0;
        current.inMainPlay = false;
        current.inBoss     = false;
    }

    // IGT accumulator: bank the per-run tick count when the run ends.
    bool runJustEnded = ((long)vars.lastHelperPtr != 0) && (current.helperPtr == 0);
    if (runJustEnded) {
        vars.igtAccumTicks = (long)vars.igtAccumTicks + (long)(int)vars.lastRealTime;
        ((Action<object>)vars.Log)("Run ended, banked " + vars.lastRealTime
            + " ticks (total " + vars.igtAccumTicks + ")");
    }
    vars.lastRealTime  = current.realTime;
    vars.lastHelperPtr = current.helperPtr;

    // Periodic gameplay-state diagnostic. Every ~2s, log key field values so
    // we can verify reads. Fires even when helperPtr is 0, so we can tell
    // whether the script is alive but waiting for gameplay vs reading garbage.
    double nowSec = Environment.TickCount / 1000.0;
    if (nowSec - (double)vars.LastDiagLogSec >= 2.0) {
        vars.LastDiagLogSec = nowSec;
        // Cross-check: GameMaster.gameStats is never assigned in source, so should be 0.
        long gmStats = 0;
        try { gmStats = (long)(uint)game.ReadValue<int>((IntPtr)(long)vars.Addr_GameMaster_gameStats); } catch {}
        ((Action<object>)vars.Log)("state: helper=0x" + current.helperPtr.ToString("X")
            + " realTime=" + current.realTime
            + " inMainPlay=" + current.inMainPlay
            + " inBoss=" + current.inBoss
            + " stats=0x" + current.statsPtr.ToString("X")
            + " gmStats=0x" + gmStats.ToString("X") + (gmStats == 0 ? " (OK)" : " (NONZERO!)")
            + " finMissions=" + current.finMissions
            + " finStory=" + current.finStory
            + " lastFloor=" + current.lastFloor
            + " infMode=" + current.infMode);
    }
}

start
{
    if (current.infMode) return false;

    // Kickstart: if init completed mid-gameplay (current.inMainPlay is already
    // true but we never observed the false->true transition), fire start
    // immediately on the first post-init tick. JustInitialized is set by the
    // init code path and cleared here.
    bool kickstart = (bool)vars.JustInitialized
        && current.inMainPlay == true
        && current.helperPtr != 0;
    if (kickstart) {
        vars.JustInitialized = false;
        vars.igtAccumTicks = 0L;
        vars.lastRealTime  = 0;
        ((Action<object>)vars.Log)("Timer start (kickstart: init completed mid-gameplay; realTime=" + current.realTime + ").");
        return true;
    }
    // Once we've observed any normal tick post-init, clear JustInitialized
    // so we don't kickstart later when the user is genuinely on a menu.
    if ((bool)vars.JustInitialized) vars.JustInitialized = false;

    if (old.inMainPlay == false && current.inMainPlay == true && current.helperPtr != 0)
    {
        vars.igtAccumTicks = 0L;
        vars.lastRealTime  = 0;
        ((Action<object>)vars.Log)("Timer start (transition: inMainPlay false->true).");
        return true;
    }
    return false;
}

gameTime
{
    long totalTicks = (long)vars.igtAccumTicks + (long)current.realTime;
    return TimeSpan.FromSeconds(totalTicks / 60.0);
}

isLoading { return true; }

split
{
    if (current.infMode) return false;
    if (settings["split_missions"] && old.finMissions == false && current.finMissions == true) {
        ((Action<object>)vars.Log)("Split 1: missions finished / key.");
        return true;
    }
    if (settings["split_boss"] && old.finStory == false && current.finStory == true) {
        ((Action<object>)vars.Log)("Split 2: boss defeated.");
        return true;
    }
    return false;
}

reset
{
    if (!settings["reset_new_game"]) return false;
    bool wipedMissions = (old.finMissions  && !current.finMissions);
    bool wipedStory    = (old.finStory     && !current.finStory);
    bool wipedFloor    = (old.lastFloor > 0 && current.lastFloor == 0);
    bool wipedDeaths   = (old.numDied   > 0 && current.numDied   == 0);
    if (wipedMissions || wipedStory || wipedFloor || wipedDeaths) {
        ((Action<object>)vars.Log)("New Game detected -> reset.");
        return true;
    }
    return false;
}

exit
{
    timer.IsGameTimePaused = true;
    vars.Initialized = false;
}

shutdown { }
