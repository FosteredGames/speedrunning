// LiveSplit auto-splitter for Knightmare Tower (Steam, Unity 4.3.4f1, Mono 2.x, x86).
// SELF-CONTAINED -- no asl-help, no external libraries.
//
// Splits:
//   1. All missions complete + key obtained  (Master.stats.finishedMissions -> true)
//   2. Final boss killed (last hit)          (Global.finishedBoss          -> true)
//      Fires inside BossBase.die() so RealTime matches the community rule
//      "RealTime to last hit". A single split captures both timing methods
//      simultaneously, so IGT is also correct at the kill moment.
//
// Start:     GameMaster.canPause false -> true (cutscene + 1s black fade +
//            1.8s camera tween all complete). Multiple detection paths
//            (statsPtr change, alreadyPlayed flip, post-completion escape,
//            mid-run reset) all ARM the same pending flag, ensuring exact
//            parity in timing -- canPause fires identically regardless of
//            which path armed it. The .lss carries Offset = +00:00:02.8 so
//            the timer reads 2.8s at canPause-true, i.e. starts counting
//            from the .mp4-end moment (including the post-movie transition).
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
    vars.ScriptVersion = "2026-05-26T13:00Z (74118c6+init-arm-on-canPause-false)";
    print("[KT] script loaded -- version " + vars.ScriptVersion);

    settings.Add("split_missions", true,  "Split when all missions complete (key obtained)");
    settings.Add("split_boss",     true,  "Split on final boss defeat");
    settings.Add("reset_new_game", true,  "Auto-reset when a New Game is started");
    settings.Add("start_new_game", true,  "Auto-start timer when a New Game is accepted (cutscene plays for ~30.5s — set .lss Offset to -00:00:30.5 so timer reaches 0 when cutscene ends)");
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

        // === HARDCODED OFFSETS (confirmed for Knightmare Tower's Mono 2.x build) ===
        // See /home/ubuntu/.claude/projects/.../memory/reference_kt_mono_layout.md.
        // If the game updates and these break, brute-force version is at git commit f5409ab.
        // MonoDomain
        const int O_DOMAIN_ASSEMBLIES = 0x6C;
        // GSList { void *data @+0; GSList *next @+4; }  -- standard glib layout
        // MonoAssembly
        const int O_ASM_NAME  = 0x08; // aname.name string
        const int O_ASM_IMAGE = 0x40; // MonoImage*
        // MonoImage
        const int O_IMG_NAME        = 0x18; // assembly name back-ref
        const int O_IMG_CLASS_CACHE = 0x2B4; // MonoInternalHashTable::table (bucket array ptr)
        // MonoClass (size 0xD0 in this slim build)
        const int O_CLS_NAME         = 0x30;
        const int O_CLS_FIELD_COUNT  = 0x64;
        const int O_CLS_FIELDS       = 0x74; // MonoClassField[] (16 bytes each)
        const int O_CLS_RUNTIME_INFO = 0xA4; // MonoClassRuntimeInfo*
        const int O_CLS_NEXT_CACHE   = 0xA8; // chain pointer in class_cache buckets
        // MonoClassRuntimeInfo { int max_domain @+0; MonoVTable *domain_vtables[] @+4; }
        const int O_RTI_VTABLES = 0x04;
        // MonoVTable
        const int O_VT_STATIC_DATA = 0x0C; // POINTER to static field storage
        // MonoClassField (16 bytes)
        const int F_NAME   = 0x04;
        const int F_OFFSET = 0x0C;
        const int F_SIZE   = 0x10;

        // === Local helpers ===
        Func<long, bool> looksLikeHeap = (a) => (a >= 0x00010000 && a < 0x80000000);
        Func<long, string> readCStr = (addr) => {
            if (addr == 0) return null;
            try {
                byte[] buf = proc.ReadBytes((IntPtr)addr, 128);
                if (buf == null) return null;
                int end = 0;
                while (end < buf.Length && buf[end] != 0) end++;
                return System.Text.Encoding.UTF8.GetString(buf, 0, end);
            } catch { return null; }
        };

        // === Step 1: Find Assembly-CSharp via GSList walk ===
        long asmCSharp = 0;
        {
            long node;
            try { node = (long)(uint)proc.ReadValue<int>((IntPtr)(rootDomain + O_DOMAIN_ASSEMBLIES)); } catch { return false; }
            int walked = 0;
            while (node != 0 && walked < 64) {
                long asmPtr;
                try { asmPtr = (long)(uint)proc.ReadValue<int>((IntPtr)node); } catch { break; }
                if (asmPtr != 0 && looksLikeHeap(asmPtr)) {
                    long nmPtr;
                    try { nmPtr = (long)(uint)proc.ReadValue<int>((IntPtr)(asmPtr + O_ASM_NAME)); } catch { nmPtr = 0; }
                    if (looksLikeHeap(nmPtr)) {
                        string nm = readCStr(nmPtr);
                        if (nm == "Assembly-CSharp") { asmCSharp = asmPtr; break; }
                    }
                }
                long nxt;
                try { nxt = (long)(uint)proc.ReadValue<int>((IntPtr)(node + 4)); } catch { break; }
                if (nxt == node) break;
                node = nxt;
                walked++;
            }
        }
        if (asmCSharp == 0) {
            logOnce("waitAsm", "Assembly-CSharp not in domain_assemblies yet (game still loading)");
            return false;
        }

        // === Step 2: Get MonoImage and verify ===
        long imageAddr;
        try { imageAddr = (long)(uint)proc.ReadValue<int>((IntPtr)(asmCSharp + O_ASM_IMAGE)); } catch { return false; }
        if (!looksLikeHeap(imageAddr)) { logOnce("badImg", "Assembly-CSharp image ptr invalid: 0x" + imageAddr.ToString("X")); return false; }
        long imgNamePtr;
        try { imgNamePtr = (long)(uint)proc.ReadValue<int>((IntPtr)(imageAddr + O_IMG_NAME)); } catch { return false; }
        string imgName = readCStr(imgNamePtr);
        if (imgName != "Assembly-CSharp") {
            logOnce("badImgName", "Image @0x" + imageAddr.ToString("X") + " has name '" + (imgName ?? "<null>") + "', expected 'Assembly-CSharp'. Mono layout may have changed.");
            return false;
        }
        logOnce("img", "Assembly-CSharp image @ 0x" + imageAddr.ToString("X"));

        // === Step 3: Find target classes by walking class_cache buckets + chains ===
        long classCacheTbl;
        try { classCacheTbl = (long)(uint)proc.ReadValue<int>((IntPtr)(imageAddr + O_IMG_CLASS_CACHE)); } catch { return false; }
        if (!looksLikeHeap(classCacheTbl)) { logOnce("noCacheTbl", "class_cache table ptr invalid"); return false; }

        var wanted = new HashSet<string> {
            "Master", "GameMaster", "GameStats", "GameHelper", "LevelEventMonitor", "Global"
        };
        var classes = new Dictionary<string, long>();
        // Mono's class_cache uses prime-sized hashtables. Don't know the exact size,
        // scan up to 1024 buckets which covers all plausible primes for this game.
        for (int b = 0; b < 1024 && classes.Count < wanted.Count; b++) {
            long cls;
            try { cls = (long)(uint)proc.ReadValue<int>((IntPtr)(classCacheTbl + b*4)); } catch { break; }
            var seen = new HashSet<long>();
            int guard = 0;
            while (looksLikeHeap(cls) && guard++ < 4096 && !seen.Contains(cls)) {
                seen.Add(cls);
                long nmPtr;
                try { nmPtr = (long)(uint)proc.ReadValue<int>((IntPtr)(cls + O_CLS_NAME)); } catch { break; }
                if (looksLikeHeap(nmPtr)) {
                    string nm = readCStr(nmPtr);
                    if (nm != null && wanted.Contains(nm) && !classes.ContainsKey(nm)) {
                        classes[nm] = cls;
                        logOnce("cls:" + nm, "  found class " + nm + " @ 0x" + cls.ToString("X"));
                    }
                }
                try { cls = (long)(uint)proc.ReadValue<int>((IntPtr)(cls + O_CLS_NEXT_CACHE)); } catch { break; }
            }
        }
        var missing = new List<string>();
        foreach (var n in wanted) if (!classes.ContainsKey(n)) missing.Add(n);
        if (missing.Count > 0) {
            logOnce("waitClasses", "Waiting on classes (not yet loaded by game): " + string.Join(", ", missing.ToArray()));
            return false;
        }

        // === Step 4: Walk MonoClassField arrays to find field offsets per class ===
        Func<long, Dictionary<string,int>> readFieldOffsets = (clsPtr) => {
            var result = new Dictionary<string,int>();
            long fp;
            int fc;
            try {
                fp = (long)(uint)proc.ReadValue<int>((IntPtr)(clsPtr + O_CLS_FIELDS));
                fc = proc.ReadValue<int>((IntPtr)(clsPtr + O_CLS_FIELD_COUNT));
            } catch { return result; }
            if (fp == 0 || fc <= 0 || fc > 200) return result;
            for (int i = 0; i < fc; i++) {
                long fPtr = fp + i * F_SIZE;
                long namePtr;
                int off;
                try {
                    namePtr = (long)(uint)proc.ReadValue<int>((IntPtr)(fPtr + F_NAME));
                    off     = proc.ReadValue<int>((IntPtr)(fPtr + F_OFFSET));
                } catch { continue; }
                if (!looksLikeHeap(namePtr)) continue;
                string nm = readCStr(namePtr);
                if (nm != null) result[nm] = off;
            }
            return result;
        };
        var fMaster = readFieldOffsets(classes["Master"]);
        var fGM     = readFieldOffsets(classes["GameMaster"]);
        var fGlobal = readFieldOffsets(classes["Global"]);
        var fLevel  = readFieldOffsets(classes["LevelEventMonitor"]);
        var fStats  = readFieldOffsets(classes["GameStats"]);
        var fHelper = readFieldOffsets(classes["GameHelper"]);

        // Require all the fields we'll actually read. Missing means Mono hasn't
        // populated the fields array for that class yet -- retry next pass.
        string[] needMaster = new string[] { "_stats" };
        string[] needGM     = new string[] { "helper", "gameStats", "_canPause" };
        string[] needGlobal = new string[] { "finishedBoss", "infiniteMode" };
        string[] needLevel  = new string[] { "numDoors" };
        string[] needStats  = new string[] { "finishedMissions", "finishedStory", "lastFloor", "numdied", "alreadyPlayed" };
        string[] needHelper = new string[] { "realTime", "isInMainGameplay", "inBoss" };
        Func<string, Dictionary<string,int>, string[], string> checkFields = (lbl, dict, names) => {
            foreach (var n in names) if (!dict.ContainsKey(n)) return lbl + "." + n;
            return null;
        };
        string missF =
            checkFields("Master",            fMaster, needMaster) ??
            checkFields("GameMaster",        fGM,     needGM)     ??
            checkFields("Global",            fGlobal, needGlobal) ??
            checkFields("LevelEventMonitor", fLevel,  needLevel)  ??
            checkFields("GameStats",         fStats,  needStats)  ??
            checkFields("GameHelper",        fHelper, needHelper);
        if (missF != null) {
            logOnce("waitFields", "Waiting on fields (not yet populated): " + missF);
            return false;
        }

        // === Step 5: Compute static base per class ===
        // sbase = read(read(cls + 0xA4) + 0x04) + 0x0C)
        Func<long, long> staticBase = (clsPtr) => {
            try {
                long rti = (long)(uint)proc.ReadValue<int>((IntPtr)(clsPtr + O_CLS_RUNTIME_INFO));
                if (rti == 0) return 0L;
                long vt = (long)(uint)proc.ReadValue<int>((IntPtr)(rti + O_RTI_VTABLES));
                if (vt == 0) return 0L;
                long sd = (long)(uint)proc.ReadValue<int>((IntPtr)(vt + O_VT_STATIC_DATA));
                return sd;
            } catch { return 0L; }
        };
        long sbMaster = staticBase(classes["Master"]);
        long sbGM     = staticBase(classes["GameMaster"]);
        long sbGlobal = staticBase(classes["Global"]);
        long sbLevel  = staticBase(classes["LevelEventMonitor"]);
        if (sbMaster == 0 || sbGM == 0 || sbGlobal == 0 || sbLevel == 0) {
            logOnce("waitVt", "Waiting on MonoVTable allocation (static_data ptr not yet set for some class)");
            return false;
        }

        // === Step 6: Validate static-base computation ===
        // GameMaster.gameStats is never assigned in source, so it must read as 0.
        // If non-zero, our static_data ptr is wrong and reads will be garbage.
        long gmsTest;
        try { gmsTest = (long)(uint)proc.ReadValue<int>((IntPtr)(sbGM + fGM["gameStats"])); } catch { gmsTest = -1; }
        if (gmsTest != 0) {
            logOnce("validFail", "Static-base validation failed: GameMaster.gameStats expected 0, got 0x"
                + gmsTest.ToString("X") + ". MonoVTable layout may have shifted; check static_data offset.");
            return false;
        }

        // === Step 7: Store final addresses ===
        var vd = (IDictionary<string,object>)vars;
        vd["Addr_Master_stats"]         = sbMaster + fMaster["_stats"];
        vd["Addr_GameMaster_helper"]    = sbGM     + fGM["helper"];
        vd["Addr_GameMaster_gameStats"] = sbGM     + fGM["gameStats"];
        vd["Addr_GameMaster_canPause"]  = sbGM     + fGM["_canPause"];
        vd["Addr_numDoors"]             = sbLevel  + fLevel["numDoors"];
        vd["Addr_finishedBoss"]         = sbGlobal + fGlobal["finishedBoss"];
        vd["Addr_infiniteMode"]         = sbGlobal + fGlobal["infiniteMode"];
        vd["Foff_finishedMissions"]     = fStats["finishedMissions"];
        vd["Foff_finishedStory"]        = fStats["finishedStory"];
        vd["Foff_lastFloor"]            = fStats["lastFloor"];
        vd["Foff_numdied"]              = fStats["numdied"];
        vd["Foff_alreadyPlayed"]        = fStats["alreadyPlayed"];
        vd["Foff_realTime"]             = fHelper["realTime"];
        vd["Foff_isInMainGameplay"]     = fHelper["isInMainGameplay"];
        vd["Foff_inBoss"]               = fHelper["inBoss"];

        logOnce("ready", "  &Master._stats=0x" + ((long)vd["Addr_Master_stats"]).ToString("X")
            + " &GameMaster.helper=0x" + ((long)vd["Addr_GameMaster_helper"]).ToString("X")
            + " sbMaster=0x" + sbMaster.ToString("X")
            + " sbGM=0x" + sbGM.ToString("X")
            + " sbGlobal=0x" + sbGlobal.ToString("X")
            + " sbLevel=0x" + sbLevel.ToString("X"));

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
    vars.LogEnabled         = settings["debug"];
    vars.Initialized        = false;
    vars.JustInitialized    = false;
    // PendingCutsceneEnd: armed by any New-Game detection (statsPtr change,
    // alreadyPlayed flip, post-completion Ended-state escape, mid-run reset
    // transition). Consumed when GameMaster.canPause goes false -> true --
    // the cutscene + 1s black fade + 1.8s camera tween have all completed
    // and control returns to the player. This is the unified start moment
    // that produces exact parity across all New-Game paths. The .lss carries
    // a +2.8s Offset so the timer reads 2.8s at canPause-true (i.e. starts
    // counting from .mp4-end, including the post-movie transition).
    vars.PendingCutsceneEnd = false;
    vars.LastDiagLogSec     = 0.0;
    vars.InitTries          = 0;
    // Validation instrumentation: when start fires we stash the wall-clock
    // ms and the arming path; when realTime ticks for the first time we log
    // the canPause-to-knight-launch elapsed time. Sanity check that the
    // detection moment is consistent across paths.
    vars.LastStartTickMs    = 0L;
    vars.LastStartReason    = "";
    refreshRate             = 60;

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
    current.canPause  = game.ReadValue<bool>((IntPtr)(long)vars.Addr_GameMaster_canPause);

    if (current.statsPtr != 0) {
        current.finMissions   = game.ReadValue<bool>((IntPtr)(current.statsPtr + (int)vars.Foff_finishedMissions));
        current.finStory      = game.ReadValue<bool>((IntPtr)(current.statsPtr + (int)vars.Foff_finishedStory));
        current.lastFloor     = game.ReadValue<int> ((IntPtr)(current.statsPtr + (int)vars.Foff_lastFloor));
        current.numDied       = game.ReadValue<int> ((IntPtr)(current.statsPtr + (int)vars.Foff_numdied));
        current.alreadyPlayed = game.ReadValue<bool>((IntPtr)(current.statsPtr + (int)vars.Foff_alreadyPlayed));
    } else {
        current.finMissions   = false;
        current.finStory      = false;
        current.lastFloor     = 0;
        current.numDied       = 0;
        current.alreadyPlayed = false;
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

    // canPause-to-knight-launch duration log. Now that start fires at
    // canPause false -> true, this measures how long the player took to
    // press launch after gaining control. Useful only as sanity-check
    // (consistent across paths confirms canPause trigger fires identically).
    if ((long)vars.LastStartTickMs != 0L
        && (int)vars.lastRealTime == 0
        && current.realTime > 0)
    {
        long elapsedMs = (long)Environment.TickCount - (long)vars.LastStartTickMs;
        ((Action<object>)vars.Log)("Cutscene-to-gameplay: "
            + (elapsedMs / 1000.0).ToString("F3") + "s"
            + " (after start via " + (string)vars.LastStartReason + ")");
        vars.LastStartTickMs = 0L;
        vars.LastStartReason = "";
    }

    // === Post-completion New Game escape hatch ===
    // After Split 2 fires the timer enters TimerPhase.Ended, in which state
    // LiveSplit's ScriptableAutoSplit (ASLScript.cs:324-368) calls neither
    // `reset` nor `start` -- both are gated to Running/Paused and NotRunning
    // respectively. So if the user clicks New Game from the post-completion
    // main menu, our reset/start blocks never see the statsPtr transition
    // and the timer stays stuck on the finished run.
    //
    // Workaround: detect the transition here (update IS called every tick
    // regardless of phase) and programmatically Reset() via a user-script
    // TimerModel. Reset is synchronous, so by the time control reaches the
    // NotRunning branch later in the same DoUpdate cycle, our start block
    // can fire and the new run kicks off without the user touching anything.
    // Use ContainsKey rather than `vars.TimerModel == null` -- accessing an
    // undefined ExpandoObject property via dynamic dispatch throws
    // RuntimeBinderException, which would kill the rest of update silently.
    if (!((IDictionary<string,object>)vars).ContainsKey("TimerModel")) {
        vars.TimerModel = new LiveSplit.Model.TimerModel { CurrentState = timer };
    }
    if (settings["reset_new_game"]
        && timer.CurrentPhase == LiveSplit.Model.TimerPhase.Ended
        && current.statsPtr != old.statsPtr
        && current.statsPtr != 0
        && old.statsPtr != 0)
    {
        vars.PendingCutsceneEnd = true;
        vars.LastStartReason    = "ended-state-escape";
        ((Action<object>)vars.Log)("Post-completion New Game (timer in Ended state) -- programmatic Reset (stats 0x"
            + old.statsPtr.ToString("X") + " -> 0x" + current.statsPtr.ToString("X") + ").");
        // Reset(false) -- skip the "save splits?" prompt. The user can save
        // their PB through LiveSplit's normal Save mechanism if they want;
        // popping a modal dialog mid-auto-flow would defeat the purpose.
        vars.TimerModel.Reset(false);
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
        ((Action<object>)vars.Log)("state: phase=" + timer.CurrentPhase
            + " helper=0x" + current.helperPtr.ToString("X")
            + " realTime=" + current.realTime
            + " inMainPlay=" + current.inMainPlay
            + " inBoss=" + current.inBoss
            + " stats=0x" + current.statsPtr.ToString("X")
            + " gmStats=0x" + gmStats.ToString("X") + (gmStats == 0 ? " (OK)" : " (NONZERO!)")
            + " finMissions=" + current.finMissions
            + " finStory=" + current.finStory
            + " finBoss=" + current.finBoss
            + " alreadyPlayed=" + current.alreadyPlayed
            + " canPause=" + current.canPause
            + " lastFloor=" + current.lastFloor
            + " infMode=" + current.infMode);
        // Dump 0x40 bytes around &Master._stats and &GameMaster.helper so we
        // can see if our addresses point to real static-data regions or zeros.
        // Only first time after init complete.
        if (!((IDictionary<string,object>)vars).ContainsKey("StaticAreaDumped")) {
            vars.StaticAreaDumped = true;
            try {
                long aStatsAddr  = (long)vars.Addr_Master_stats;
                long aHelperAddr = (long)vars.Addr_GameMaster_helper;
                ((Action<object>)vars.Log)("Static area inspection:");
                ((Action<object>)vars.Log)("  &Master._stats     = 0x" + aStatsAddr.ToString("X"));
                ((Action<object>)vars.Log)("  &GameMaster.helper = 0x" + aHelperAddr.ToString("X"));
                long mStatsBase = aStatsAddr - 0x10;  // _stats.offset is 0x10
                long gmHelperBase = aHelperAddr;       // helper.offset is 0
                // Dump 0x40 bytes starting from each computed sbase.
                byte[] mBuf = null, gmBuf = null;
                try { mBuf  = game.ReadBytes((IntPtr)mStatsBase, 0x40); } catch {}
                try { gmBuf = game.ReadBytes((IntPtr)gmHelperBase, 0x40); } catch {}
                if (mBuf != null) {
                    for (int i = 0; i + 4 <= mBuf.Length; i += 4) {
                        uint v = BitConverter.ToUInt32(mBuf, i);
                        ((Action<object>)vars.Log)("    Master.sbase+0x" + i.ToString("X2") + " = 0x" + v.ToString("X8"));
                    }
                }
                if (gmBuf != null) {
                    for (int i = 0; i + 4 <= gmBuf.Length; i += 4) {
                        uint v = BitConverter.ToUInt32(gmBuf, i);
                        ((Action<object>)vars.Log)("    GameMaster.sbase+0x" + i.ToString("X2") + " = 0x" + v.ToString("X8"));
                    }
                }
            } catch {}
        }
    }
}

start
{
    if (current.infMode) return false;

    // === New Game detection (ARMS pending flag; doesn't fire start) ===
    // Each detection path observes a different early moment of the New Game
    // flow, but ALL of them converge at the same later moment: GameMaster.
    // canPause going false -> true, which is when the camera fade-in tween
    // completes and control returns to the player (FPI.beginGameplayForReal
    // at FPI.cs:525). We arm here, fire at canPause below -- this guarantees
    // exact parity across paths.
    if (settings["start_new_game"]) {
        // Path B: statsPtr reassigned (in-game New Game). StatsCentral.reset()
        // creates a new GameStats instance and reassigns Master.stats
        // (StatsCentral.cs:96).
        bool statsReassigned = current.statsPtr != old.statsPtr
            && current.statsPtr != 0
            && old.statsPtr != 0;
        if (statsReassigned && !(bool)vars.PendingCutsceneEnd) {
            vars.PendingCutsceneEnd = true;
            vars.LastStartReason    = "B-stats-reassign";
            ((Action<object>)vars.Log)("Arm cutscene-end start (B: stats reassigned 0x"
                + old.statsPtr.ToString("X") + " -> 0x" + current.statsPtr.ToString("X") + ").");
        }
        // Path B2: alreadyPlayed false -> true (fresh-install auto-intro).
        // On a fresh save FPI.showMainMenu2() routes alreadyPlayed=false
        // straight into showIntro() without showing the main menu, so the
        // user never clicks New Game and path B never fires. showIntro() sets
        // alreadyPlayed = true as its FIRST line (FPI.cs:829) before playing
        // the movie.
        if (current.statsPtr != 0
            && old.alreadyPlayed == false
            && current.alreadyPlayed == true
            && !(bool)vars.PendingCutsceneEnd)
        {
            vars.PendingCutsceneEnd = true;
            vars.LastStartReason    = "B2-alreadyPlayed-flip";
            ((Action<object>)vars.Log)("Arm cutscene-end start (B2: alreadyPlayed false -> true).");
        }
    }

    // === FIRE: canPause false -> true (cutscene + camera tween complete) ===
    // GameMaster.canPause is set true at the end of the 1.8s camera-fade-in
    // tween (FPI.beginGameplayForReal at FPI.cs:525), which is exactly 2.8s
    // after the .mp4 last frame plays (1s WaitToDo black-fade + 1.8s HOTween).
    // The .lss has Offset = +00:00:02.8 so the timer reads 2.8s at this
    // moment -- i.e. it begins counting from the .mp4-end moment, including
    // the post-movie black-fade and camera-tween in the displayed run time.
    if ((bool)vars.PendingCutsceneEnd
        && old.canPause == false
        && current.canPause == true)
    {
        vars.PendingCutsceneEnd = false;
        vars.igtAccumTicks      = 0L;
        vars.lastRealTime       = 0;
        vars.LastStartTickMs    = (long)Environment.TickCount;
        ((Action<object>)vars.Log)("Timer start (canPause false->true -- cutscene+tween complete; armed by "
            + (string)vars.LastStartReason + ").");
        return true;
    }

    // === Init-time arming: attached while canPause=false ===
    // Init can complete after showIntro has already fired (e.g. game restart
    // mid-cutscene -- save persists alreadyPlayed=false on disk, game auto-
    // routes to showIntro, alreadyPlayed flips to true BEFORE our init
    // finishes Mono walking). We don't observe the alreadyPlayed transition
    // in that case. Same blind spot applies to anyone attaching LiveSplit
    // after the game is already running.
    //
    // Mitigation: if canPause is false at init time, arm the pending flag
    // -- the next canPause false->true will fire start. Safe in both
    // ambiguous interpretations of "canPause=false at init":
    //   - User in the cutscene: fires at the correct moment when control
    //     returns (cutscene + tween complete).
    //   - User at the main menu: stays armed until they click New Game and
    //     proceed through the cutscene; canPause flip at the end fires
    //     start as intended.
    // If canPause is already true at init (player attached mid-gameplay or
    // at the launcher post-cutscene), the kickstart path below handles it.
    if ((bool)vars.JustInitialized
        && current.helperPtr != 0
        && current.canPause == false
        && !(bool)vars.PendingCutsceneEnd)
    {
        vars.JustInitialized    = false;
        vars.PendingCutsceneEnd = true;
        vars.LastStartReason    = "init-canPause-false";
        ((Action<object>)vars.Log)("Arm cutscene-end start (init: canPause=false at attach; awaiting next false->true).");
        return false;
    }

    // === Kickstart: init completed with canPause=true (mid-gameplay) ===
    // For when LiveSplit attaches while the user is already in the tower.
    // The .lss +2.8s offset is wrong here (no cutscene/tween to compensate
    // for), so runs started this way shouldn't be submitted -- it's
    // primarily a development convenience.
    bool kickstart = (bool)vars.JustInitialized
        && current.inMainPlay == true
        && current.helperPtr != 0;
    if (kickstart) {
        vars.JustInitialized = false;
        vars.igtAccumTicks   = 0L;
        vars.lastRealTime    = 0;
        vars.LastStartTickMs = 0L;
        vars.LastStartReason = "";
        ((Action<object>)vars.Log)("Timer start (kickstart: init completed mid-gameplay; realTime=" + current.realTime + ").");
        return true;
    }
    if ((bool)vars.JustInitialized) vars.JustInitialized = false;

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
    if (settings["split_boss"] && old.finBoss == false && current.finBoss == true) {
        ((Action<object>)vars.Log)("Split 2: boss defeated (last hit -- Global.finishedBoss).");
        return true;
    }
    return false;
}

reset
{
    if (!settings["reset_new_game"]) return false;
    // PRIMARY signal: StatsCentral.reset() builds a new GameStats instance and
    // reassigns Master.stats = component. The static-field pointer changes from
    // one heap value to another -- reliable on every New Game, including the
    // 2nd+ in a session (field-wipe checks miss those because the fields are
    // already at default values from the prior wipe).
    bool statsReassigned = current.statsPtr != old.statsPtr
        && current.statsPtr != 0
        && old.statsPtr != 0;
    if (statsReassigned) {
        // Hand off to the start block: arm the pending flag so start fires
        // when canPause goes false -> true (cutscene + camera tween complete).
        vars.PendingCutsceneEnd = true;
        vars.LastStartReason    = "reset-handoff";
        ((Action<object>)vars.Log)("New Game detected -> reset (stats 0x"
            + old.statsPtr.ToString("X") + " -> 0x" + current.statsPtr.ToString("X")
            + "; start will refire when canPause false->true if start_new_game is on).");
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
