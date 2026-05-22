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
//   2. Edit Splits -> Use Game Time -> Compare Against: Game Time.

state("Knightmare Tower") {}

startup
{
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
        var log    = (Action<object>)vars.Log;
        var rcstr  = (Func<Process,IntPtr,string>)vars.ReadCStr;
        var getExp = (Func<Process,long,string,long>)vars.GetExport;

        // --- mono.dll base ---
        long monoBase = ((Func<Process,long>)vars.GetMonoBase)(proc);
        if (monoBase == 0) { log("mono.dll not loaded yet"); return false; }
        log("mono.dll @ 0x" + monoBase.ToString("X"));

        // --- mono_get_root_domain export ---
        long fnGetRoot = getExp(proc, monoBase, "mono_get_root_domain");
        if (fnGetRoot == 0) { log("export mono_get_root_domain not found"); return false; }
        log("mono_get_root_domain @ 0x" + fnGetRoot.ToString("X"));

        // --- expect prologue: A1 XX XX XX XX (mov eax, [imm32]) ---
        byte op0 = proc.ReadValue<byte>((IntPtr)fnGetRoot);
        if (op0 != 0xA1) {
            log("Unexpected prologue 0x" + op0.ToString("X") + " (want 0xA1); Mono build differs.");
            return false;
        }
        long pRootDomain = (long)(uint)proc.ReadValue<int>((IntPtr)(fnGetRoot + 1));
        long rootDomain  = (long)(uint)proc.ReadValue<int>((IntPtr)pRootDomain);
        if (rootDomain == 0) { log("root domain not initialized yet"); return false; }
        log("MonoDomain @ 0x" + rootDomain.ToString("X"));

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

        // Wider scan: 0x08 to 0x300, and wider name-offset candidates inside
        // the candidate "assembly" (covers cases where MonoAssemblyName isn't
        // the first embedded struct after the header).
        int[] nameOffCandidates = new int[] {
            0x00, 0x04, 0x08, 0x0C, 0x10, 0x14, 0x18, 0x1C, 0x20,
            0x24, 0x28, 0x2C, 0x30, 0x34, 0x38, 0x3C, 0x40
        };
        for (int dOff = 0x08; dOff <= 0x300 && foundDomOff < 0; dOff += 4) {
            long gslist;
            try { gslist = (long)(uint)proc.ReadValue<int>((IntPtr)(rootDomain + dOff)); } catch { continue; }
            if (!looksLikeHeap(gslist)) continue;
            long firstAsm;
            try { firstAsm = (long)(uint)proc.ReadValue<int>((IntPtr)gslist); } catch { continue; }
            if (!looksLikeHeap(firstAsm)) continue;
            long nxt;
            try { nxt = (long)(uint)proc.ReadValue<int>((IntPtr)(gslist + 4)); } catch { continue; }
            if (nxt != 0 && !looksLikeHeap(nxt)) continue;

            foreach (int nOff in nameOffCandidates) {
                long namePtr;
                try { namePtr = (long)(uint)proc.ReadValue<int>((IntPtr)(firstAsm + nOff)); } catch { continue; }
                if (!looksLikeHeap(namePtr)) continue;
                string nm = tryReadAsCStr(namePtr);
                if (nm != null && knownAsms.Contains(nm)) {
                    foundDomOff = dOff;
                    foundNameOff = nOff;
                    foundFirstName = nm;
                    foundFirstAsm = firstAsm;
                    break;
                }
            }
        }

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
        log("AUTO-DISCOVERED: domain_assemblies @ +0x" + foundDomOff.ToString("X")
            + ", assembly_name @ +0x" + foundNameOff.ToString("X")
            + " (first asm: " + foundFirstName + ")");
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
                log("  asm[" + walked + "]: " + (aname ?? "<null>"));
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
        // The image pointer should be a heap ptr, and dereferencing+nameOff
        // on the MonoImage should give us "Assembly-CSharp" (or similar).
        int foundImageOff = -1;
        for (int iOff = 0x40; iOff <= 0x80 && foundImageOff < 0; iOff += 4) {
            long candImg;
            try { candImg = (long)(uint)proc.ReadValue<int>((IntPtr)(asmForImageProbe + iOff)); } catch { continue; }
            if (!looksLikeHeap(candImg)) continue;
            // Probe image-name offsets too -- MonoImage.assembly_name or .name
            int[] imgNameOffs = new int[] { 0x04, 0x08, 0x0C, 0x10, 0x14, 0x18 };
            foreach (int inOff in imgNameOffs) {
                long inPtr;
                try { inPtr = (long)(uint)proc.ReadValue<int>((IntPtr)(candImg + inOff)); } catch { continue; }
                if (!looksLikeHeap(inPtr)) continue;
                string s = tryReadAsCStr(inPtr);
                if (s == "Assembly-CSharp") {
                    foundImageOff = iOff;
                    vars.O_Image_Name = inOff;
                    imageAddr = candImg;
                    log("AUTO-DISCOVERED: assembly.image @ +0x" + iOff.ToString("X")
                        + ", image.name @ +0x" + inOff.ToString("X"));
                    break;
                }
            }
        }
        if (imageAddr == 0) { log("Could not locate MonoImage on Assembly-CSharp"); return false; }
        vars.O_Assembly_Image = foundImageOff;
        log("Assembly-CSharp image @ 0x" + imageAddr.ToString("X"));

        // --- AUTO-DISCOVER class_cache table + class.name offsets ---
        // Probe the MonoImage for any pointer that, when treated as a bucket
        // array, contains MonoClass-shaped objects with recognizable class
        // names from Assembly-CSharp (Master, GameMaster, MainChar, ...).
        // These are KT-specific so any hit unambiguously identifies the
        // Assembly-CSharp class_cache.
        var wanted  = new HashSet<string> {
            "Master", "GameMaster", "GameStats", "GameHelper",
            "LevelEventMonitor", "Global"
        };
        // Broader "any plausible KT class name" set for table discovery --
        // many of these only get loaded once gameplay starts, but a handful
        // are loaded eagerly with mainData.
        var probeClassNames = new HashSet<string>(wanted) {
            "MainChar", "Master", "GameMaster", "Lava", "Beast", "Page",
            "BasicEnemy", "BG", "FPI", "UI", "Initializer", "Caller",
            "AudioController", "PuppetMaster", "Pooled", "MissionMaster"
        };
        int[] classNameOffCandidates = new int[] {
            0x10, 0x14, 0x18, 0x1C, 0x20, 0x24, 0x28, 0x2C, 0x30, 0x34, 0x38, 0x3C, 0x40, 0x44, 0x48
        };

        int  foundTableOff   = -1;
        int  foundClassNameOff = -1;
        long foundTablePtr   = 0;
        int  foundBucketHits = 0;
        for (int iOff = 0x80; iOff <= 0x600 && foundTableOff < 0; iOff += 4) {
            long table;
            try { table = (long)(uint)proc.ReadValue<int>((IntPtr)(imageAddr + iOff)); } catch { continue; }
            if (!looksLikeHeap(table)) continue;

            // For each candidate class-name offset, count how many buckets
            // in the first 64 entries dereference to objects containing a
            // recognized class name AT THAT OFFSET. Highest-scoring offset wins.
            foreach (int cnOff in classNameOffCandidates) {
                int hits = 0;
                for (int b = 0; b < 64; b++) {
                    long bucket;
                    try { bucket = (long)(uint)proc.ReadValue<int>((IntPtr)(table + b*4)); } catch { break; }
                    if (!looksLikeHeap(bucket)) continue;
                    long nmPtr;
                    try { nmPtr = (long)(uint)proc.ReadValue<int>((IntPtr)(bucket + cnOff)); } catch { continue; }
                    if (!looksLikeHeap(nmPtr)) continue;
                    string s = tryReadAsCStr(nmPtr);
                    if (s != null && probeClassNames.Contains(s)) hits++;
                }
                if (hits >= 1 && hits > foundBucketHits) {
                    foundTableOff     = iOff;
                    foundClassNameOff = cnOff;
                    foundTablePtr     = table;
                    foundBucketHits   = hits;
                }
            }
        }

        if (foundTableOff < 0) {
            log("class_cache table auto-discovery failed; running exploratory probe...");
            // Print every plausible class name we can reach from any heap
            // ptr in MonoImage, at any class-name candidate offset.
            int printed = 0;
            for (int iOff = 0x80; iOff <= 0x600 && printed < 80; iOff += 4) {
                long table;
                try { table = (long)(uint)proc.ReadValue<int>((IntPtr)(imageAddr + iOff)); } catch { continue; }
                if (!looksLikeHeap(table)) continue;
                int seenHere = 0;
                for (int b = 0; b < 32 && seenHere < 4; b++) {
                    long bucket;
                    try { bucket = (long)(uint)proc.ReadValue<int>((IntPtr)(table + b*4)); } catch { break; }
                    if (!looksLikeHeap(bucket)) continue;
                    foreach (int cnOff in classNameOffCandidates) {
                        long nmPtr;
                        try { nmPtr = (long)(uint)proc.ReadValue<int>((IntPtr)(bucket + cnOff)); } catch { continue; }
                        if (!looksLikeHeap(nmPtr)) continue;
                        string s = tryReadAsCStr(nmPtr);
                        if (s != null && s.Length >= 3 && s.Length <= 40) {
                            log("  img+0x" + iOff.ToString("X3") + " buck[" + b + "] cls+0x" + cnOff.ToString("X2") + " -> \"" + s + "\"");
                            printed++; seenHere++;
                            if (seenHere >= 4 || printed >= 80) break;
                        }
                    }
                }
            }
            return false;
        }

        log("AUTO-DISCOVERED: class_cache table @ img+0x" + foundTableOff.ToString("X")
            + ", class.name @ +0x" + foundClassNameOff.ToString("X")
            + " (" + foundBucketHits + " KT classes found in first 64 buckets)");

        // The MonoInternalHashTable's size field lives near the table ptr.
        // Probe the 8 words before it for a plausible bucket count (a power
        // of 2 in the 16..65536 range is the strong signal).
        int foundSize = 0;
        for (int delta = -32; delta <= -4; delta += 4) {
            int cand;
            try { cand = proc.ReadValue<int>((IntPtr)(imageAddr + foundTableOff + delta)); } catch { continue; }
            if (cand >= 16 && cand <= 0x10000 && (cand & (cand - 1)) == 0) {
                foundSize = cand;
                log("  found bucket count " + cand + " at img+0x" + (foundTableOff + delta).ToString("X"));
                break;
            }
        }
        if (foundSize == 0) {
            // Fall back: scan buckets until we hit several consecutive
            // unreadable / non-heap entries.
            int consecutiveBad = 0;
            int b;
            for (b = 0; b < 65536; b++) {
                long bucket;
                try { bucket = (long)(uint)proc.ReadValue<int>((IntPtr)(foundTablePtr + b*4)); }
                catch { break; }
                if (bucket == 0) { consecutiveBad = 0; continue; }
                if (!looksLikeHeap(bucket)) { consecutiveBad++; if (consecutiveBad > 8) break; }
                else consecutiveBad = 0;
            }
            foundSize = b;
            log("  bucket count (heuristic): " + foundSize);
        }

        vars.Image_ClassCache_TableAbs = imageAddr + foundTableOff;
        vars.O_Class_Name = foundClassNameOff;
        int bucketCount = foundSize;
        long bucketArr  = foundTablePtr;

        // --- find every class we need by name ---
        // We don't yet know the within-bucket chain offset. Strategy:
        //   Pass 1: scan only bucket HEADS (no chaining). Most needed classes
        //           are common enough to live as bucket heads.
        //   Pass 2 (if any class missing): auto-discover the chain offset by
        //           inspecting the bucket we DID hit -- whichever pointer in
        //           it leads to another valid MonoClass is the chain link.
        var classes = new Dictionary<string, long>();
        for (int b = 0; b < bucketCount; b++) {
            long cls;
            try { cls = (long)(uint)proc.ReadValue<int>((IntPtr)(bucketArr + b*4)); } catch { continue; }
            if (!looksLikeHeap(cls)) continue;
            long nmPtr;
            try { nmPtr = (long)(uint)proc.ReadValue<int>((IntPtr)(cls + foundClassNameOff)); } catch { continue; }
            if (!looksLikeHeap(nmPtr)) continue;
            string nm = tryReadAsCStr(nmPtr);
            if (nm != null && wanted.Contains(nm) && !classes.ContainsKey(nm)) {
                classes[nm] = cls;
                log("  found class " + nm + " @ 0x" + cls.ToString("X"));
            }
        }

        // Pass 2: auto-discover chain offset if needed.
        if (classes.Count < wanted.Count) {
            log("missing " + (wanted.Count - classes.Count) + " classes after bucket-head scan; probing for chain offset...");
            long anchorCls = 0;
            foreach (var kv in classes) { anchorCls = kv.Value; break; }
            if (anchorCls == 0) {
                log("no anchor class to probe chain offset; aborting");
                return false;
            }
            int chainOff = -1;
            for (int cOff = 0x40; cOff <= 0x180 && chainOff < 0; cOff += 4) {
                long nextCls;
                try { nextCls = (long)(uint)proc.ReadValue<int>((IntPtr)(anchorCls + cOff)); } catch { continue; }
                if (!looksLikeHeap(nextCls)) continue;
                long nmPtr;
                try { nmPtr = (long)(uint)proc.ReadValue<int>((IntPtr)(nextCls + foundClassNameOff)); } catch { continue; }
                if (!looksLikeHeap(nmPtr)) continue;
                string s = tryReadAsCStr(nmPtr);
                if (s != null && s.Length >= 3 && s.Length <= 40) {
                    chainOff = cOff;
                    log("  chain offset: +0x" + cOff.ToString("X") + " (anchor next-class \"" + s + "\")");
                    break;
                }
            }
            if (chainOff < 0) {
                log("chain offset auto-discovery failed; classes might be in chains we can't follow.");
                return false;
            }
            vars.O_IHT_NextClassSlot = chainOff;
            // Re-walk including chains.
            for (int b = 0; b < bucketCount; b++) {
                long cls;
                try { cls = (long)(uint)proc.ReadValue<int>((IntPtr)(bucketArr + b*4)); } catch { continue; }
                int guard = 0;
                while (looksLikeHeap(cls) && guard++ < 4096) {
                    long nmPtr;
                    try { nmPtr = (long)(uint)proc.ReadValue<int>((IntPtr)(cls + foundClassNameOff)); } catch { break; }
                    if (looksLikeHeap(nmPtr)) {
                        string nm = tryReadAsCStr(nmPtr);
                        if (nm != null && wanted.Contains(nm) && !classes.ContainsKey(nm)) {
                            classes[nm] = cls;
                            log("  found class " + nm + " @ 0x" + cls.ToString("X") + " (via chain)");
                        }
                    }
                    try { cls = (long)(uint)proc.ReadValue<int>((IntPtr)(cls + chainOff)); } catch { break; }
                }
            }
        }
        foreach (var n in wanted) {
            if (!classes.ContainsKey(n)) { log("MISSING class: " + n); return false; }
        }

        // --- field lookup helpers ---
        Func<long, string, int> fieldOffset = (clsPtr, fieldName) => {
            long fields = (long)(uint)proc.ReadValue<int>((IntPtr)(clsPtr + (int)vars.O_Class_Fields));
            int count = proc.ReadValue<int>((IntPtr)(clsPtr + (int)vars.O_Class_FieldCount));
            if (fields == 0 || count <= 0 || count > 4096) return -1;
            for (int i = 0; i < count; i++) {
                long fPtr  = fields + i * (int)vars.O_Field_Size;
                long fnPtr = (long)(uint)proc.ReadValue<int>((IntPtr)(fPtr + (int)vars.O_Field_Name));
                string fn  = rcstr(proc, (IntPtr)fnPtr);
                if (fn == fieldName) {
                    return proc.ReadValue<int>((IntPtr)(fPtr + (int)vars.O_Field_Offset));
                }
            }
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

        // --- resolve static-field absolute addresses ---
        var dict = (IDictionary<string,object>)vars;
        Action<string, string, string> resolveStatic = (cn, fn, key) => {
            long sb = staticBase(classes[cn]);
            int off = fieldOffset(classes[cn], fn);
            if (sb == 0 || off < 0) throw new Exception("missing static " + cn + "." + fn);
            dict[key] = sb + off;
            log("  &" + cn + "." + fn + " = 0x" + (sb+off).ToString("X"));
        };
        Action<string, string, string> resolveInstance = (cn, fn, key) => {
            int off = fieldOffset(classes[cn], fn);
            if (off < 0) throw new Exception("missing instance " + cn + "." + fn);
            dict[key] = off;
            log("  offset " + cn + "." + fn + " = 0x" + off.ToString("X"));
        };

        try {
            resolveStatic ("Master",            "stats",          "Addr_Master_stats");
            resolveStatic ("GameMaster",        "helper",         "Addr_GameMaster_helper");
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
            log("resolution failed: " + ex.Message);
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
    vars.LogEnabled  = settings["debug"];
    vars.Initialized = false;
    vars.InitTries   = 0;
    refreshRate      = 60;

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
        if (vars.InitTries == 1 || vars.InitTries % 120 == 0) log("init attempt " + vars.InitTries);

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
}

start
{
    if (current.infMode) return false;
    if (old.inMainPlay == false && current.inMainPlay == true && current.helperPtr != 0)
    {
        vars.igtAccumTicks = 0L;
        vars.lastRealTime  = 0;
        ((Action<object>)vars.Log)("Timer start.");
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
