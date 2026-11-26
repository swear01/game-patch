using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Threading;
using System.Web.Script.Serialization;

// External x64 helper. No executable bytes or OpenSpeedy controller flags are patched.
// --self-test never loads speedpatch64.dll or opens another process.
// Without --apply, inspection opens target processes for read access only.
internal static class ClockIsolation
{
    const string ExpectedHash = "c72ba4d9e35c5c00efc113e541da91a02dbc0c85c6fb2effff5cee63898bc70c";
    const uint ReaderRva = 0x1170, SlotRva = 0xa458;
    static readonly byte[] Reader = Hex("4883ec1848833ddc92000000740f488b05d39200000fb600");
    static readonly Dictionary<int, Isolation> Cache = new Dictionary<int, Isolation>();
    static readonly HashSet<string> VerifiedFiles = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
    static readonly JavaScriptSerializer Json = new JavaScriptSerializer();
    static NativeSpeed GetSpeed;
    static NativeDisable Disable;
    static IntPtr Controller;
    static volatile bool Stopping;

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate double NativeSpeed();
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate void NativeDisable(uint pid);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int NativeEnabled();
    sealed class Isolation { public long Start; public IntPtr Module, Slot, Original, Zero; public bool BootstrapInjected; }
    sealed class Pe
    {
        public byte[] Bytes;
        public int Opt, Sections, Count;
        public Pe(byte[] bytes)
        {
            Bytes=bytes; int pe=BitConverter.ToInt32(bytes,0x3c);
            Require(BitConverter.ToUInt32(bytes,pe)==0x4550,"Invalid PE signature");
            Require(BitConverter.ToUInt16(bytes,pe+4)==0x8664,"DLL must be x64");
            Opt=pe+24; Require(BitConverter.ToUInt16(bytes,Opt)==0x20b,"DLL must be PE32+");
            Count=BitConverter.ToUInt16(bytes,pe+6); Sections=Opt+BitConverter.ToUInt16(bytes,pe+20);
        }
        public int Offset(uint rva)
        {
            for(int i=0;i<Count;i++)
            {
                int o=Sections+i*40; uint va=BitConverter.ToUInt32(Bytes,o+12);
                uint size=Math.Max(BitConverter.ToUInt32(Bytes,o+8),BitConverter.ToUInt32(Bytes,o+16));
                if(rva>=va && rva-va<size)return checked((int)(BitConverter.ToUInt32(Bytes,o+20)+rva-va));
            }
            throw new InvalidOperationException("RVA outside sections");
        }
        uint U32(int o){return BitConverter.ToUInt32(Bytes,o);}
        public uint Export(string name)
        {
            int e=Offset(U32(Opt+112)); uint funcs=U32(e+28),names=U32(e+32),ords=U32(e+36);
            for(int i=0;i<U32(e+24);i++)
            {
                int o=Offset(U32(Offset(names)+i*4)),end=Array.IndexOf(Bytes,(byte)0,o);
                if(System.Text.Encoding.ASCII.GetString(Bytes,o,end-o)==name)
                    return U32(Offset(funcs)+BitConverter.ToUInt16(Bytes,Offset(ords)+i*2)*4);
            }
            throw new InvalidOperationException("Missing export "+name);
        }
    }
    static void Require(bool value,string message){if(!value)throw new InvalidOperationException(message);}
    static byte[] Hex(string value){return Enumerable.Range(0,value.Length/2).Select(i=>Convert.ToByte(value.Substring(i*2,2),16)).ToArray();}
    static string Hash(byte[] bytes){using(var sha=SHA256.Create())return BitConverter.ToString(sha.ComputeHash(bytes)).Replace("-","").ToLowerInvariant();}
    static void CheckReader(byte[] code)
    {
        Require(code.SequenceEqual(Reader),"Unexpected SP_IsEnabled machine code");
        long first=ReaderRva+12+BitConverter.ToInt32(code,7),second=ReaderRva+21+BitConverter.ToInt32(code,17);
        Require(first==second && first==SlotRva && (first&7)==0,"Unexpected pEnabled pointer slot");
    }
    static void CheckFile(string path)
    {
        path=Path.GetFullPath(path); if(VerifiedFiles.Contains(path))return;
        byte[] bytes=File.ReadAllBytes(path);
        Require(Hash(bytes)==ExpectedHash,"Unsupported speedpatch64.dll SHA256: "+path);
        var pe=new Pe(bytes); Require(pe.Export("SP_IsEnabled")==ReaderRva,"Unexpected SP_IsEnabled export");
        Require(pe.Export("SP_GetSpeed")==0x1470,"Unexpected SP_GetSpeed export");
        CheckReader(bytes.Skip(pe.Offset(ReaderRva)).Take(Reader.Length).ToArray());
        VerifiedFiles.Add(path);
    }
    static byte[] Read(IntPtr process,IntPtr address,int count)
    {
        var bytes=new byte[count]; UIntPtr done;
        Require(ReadProcessMemory(process,address,bytes,(UIntPtr)count,out done) && done.ToUInt64()==(ulong)count,"ReadProcessMemory failed: "+Marshal.GetLastWin32Error());
        return bytes;
    }
    static IntPtr ReadPointer(IntPtr process,IntPtr address){return new IntPtr(BitConverter.ToInt64(Read(process,address,8),0));}
    static bool SamePath(string a,string b){return string.Equals(Path.GetFullPath(a),Path.GetFullPath(b),StringComparison.OrdinalIgnoreCase);}
    static bool EnabledRole(string commandLine){return commandLine.IndexOf("--type=",StringComparison.OrdinalIgnoreCase)<0 || commandLine.IndexOf("--type=renderer",StringComparison.OrdinalIgnoreCase)>=0;}
    static bool ShouldDisable(bool newlyLoaded){return newlyLoaded;}
    static long CreatedAt(IntPtr handle)
    {
        long created,exited,kernel,user;
        Require(GetProcessTimes(handle,out created,out exited,out kernel,out user),"Cannot read process creation time: "+Marshal.GetLastWin32Error());
        return created;
    }
    static void CheckInstance(long readerCreated,long writerCreated)
    {
        Require(readerCreated==writerCreated,"Process instance changed while opening isolation handle");
    }
    static IntPtr OpenIsolationHandle(IntPtr reader,int pid)
    {
        // Keep the verified reader alive until the writer refers to that same
        // instance. Never close the reader and then reopen only by a reusable PID.
        IntPtr writer=OpenProcess(0x43a,false,(uint)pid);
        Require(writer!=IntPtr.Zero,"OpenProcess for isolation failed");
        try { CheckInstance(CreatedAt(reader),CreatedAt(writer));return writer; }
        catch { CloseHandle(writer);throw; }
    }
    enum ModulePlan { NativeUnhooked, Bootstrap, Protect, Inspect }
    static ModulePlan PlanModules(bool controllerRole,int loaded,bool apply)
    {
        Require(loaded==0 || loaded==1,"speedpatch64.dll module count is invalid");
        // An unhooked utility already uses native clocks. In particular, do not
        // inject into Chromium's sandbox just to isolate hooks it does not have.
        if(loaded==0 && !controllerRole)return ModulePlan.NativeUnhooked;
        if(loaded==0){Require(apply,"speedpatch64.dll is not loaded exactly once");return ModulePlan.Bootstrap;}
        return apply?ModulePlan.Protect:ModulePlan.Inspect;
    }
    static ProcessModule[] PatchModules(Process process)
    {
        process.Refresh();return process.Modules.Cast<ProcessModule>().Where(m=>m.ModuleName.Equals("speedpatch64.dll",StringComparison.OrdinalIgnoreCase)).ToArray();
    }
    static void Bootstrap(Process process,IntPtr handle,string dll)
    {
        CheckFile(dll);
        byte[] path=System.Text.Encoding.Unicode.GetBytes(Path.GetFullPath(dll)+"\0");
        IntPtr memory=VirtualAllocEx(handle,IntPtr.Zero,(UIntPtr)path.Length,0x3000,4);
        Require(memory!=IntPtr.Zero,"Cannot allocate official DLL path");
        IntPtr thread=IntPtr.Zero;bool mayFree=true;
        try
        {
            UIntPtr written; Require(WriteProcessMemory(handle,memory,path,(UIntPtr)path.Length,out written)&&written.ToUInt64()==(ulong)path.Length,"Cannot write official DLL path");
            IntPtr local=GetProcAddress(GetModuleHandle("kernel32.dll"),"LoadLibraryW");
            Require(local!=IntPtr.Zero,"Missing LoadLibraryW");
            // Resolve the real containing system module, including forwarded exports.
            var localModule=Process.GetCurrentProcess().Modules.Cast<ProcessModule>().Single(m=>local.ToInt64()>=m.BaseAddress.ToInt64()&&local.ToInt64()<m.BaseAddress.ToInt64()+m.ModuleMemorySize);
            process.Refresh();var targetModule=process.Modules.Cast<ProcessModule>().Single(m=>m.ModuleName.Equals(localModule.ModuleName,StringComparison.OrdinalIgnoreCase));
            IntPtr remote=new IntPtr(targetModule.BaseAddress.ToInt64()+local.ToInt64()-localModule.BaseAddress.ToInt64());
            uint id;thread=CreateRemoteThread(handle,IntPtr.Zero,UIntPtr.Zero,remote,memory,0,out id);
            Require(thread!=IntPtr.Zero,"Cannot start official LoadLibraryW in target");
            mayFree=false;
            Require(WaitForSingleObject(thread,10000)==0,"Official DLL bootstrap timed out; path allocation retained until target exits");
            mayFree=true;
            // Never change a preexisting user flag. A new OpenSpeedy host starts enabled;
            // turn off only our own bootstrap before replacing its native reader pointer.
            if(ShouldDisable(true))Disable((uint)process.Id);
            Require(PatchModules(process).Length==1,"Official DLL bootstrap did not load speedpatch64.dll");
            Require(!ControllerEnabled(process.Id),"Newly bootstrapped target remained enabled");
        }
        finally
        {
            if(thread!=IntPtr.Zero)CloseHandle(thread);
            if(mayFree)VirtualFreeEx(handle,memory,UIntPtr.Zero,0x8000);
        }
    }
    static string CommandLine(IntPtr process)
    {
        int length; NtQueryInformationProcess(process,60,IntPtr.Zero,0,out length);
        Require(length>0 && length<1024*1024,"Cannot query process command line");
        IntPtr memory=Marshal.AllocHGlobal(length);
        try
        {
            int ignored; int status=NtQueryInformationProcess(process,60,memory,length,out ignored);
            Require(status>=0,"Cannot read process command line NTSTATUS "+status.ToString("x"));
            int chars=(ushort)Marshal.ReadInt16(memory)/2;
            return Marshal.PtrToStringUni(Marshal.ReadIntPtr(memory,8),chars);
        }
        finally{Marshal.FreeHGlobal(memory);}
    }
    static bool ControllerEnabled(int pid)
    {
        IntPtr mapping=OpenFileMapping(4,false,"OpenSpeedy."+pid.ToString(CultureInfo.InvariantCulture));
        Require(mapping!=IntPtr.Zero,"Original OpenSpeedy controller mapping missing for PID "+pid);
        try
        {
            IntPtr view=MapViewOfFile(mapping,4,0,0,(UIntPtr)1);
            Require(view!=IntPtr.Zero,"Cannot read original controller mapping");
            try{return Marshal.ReadByte(view)!=0;}finally{UnmapViewOfFile(view);}
        }
        finally{CloseHandle(mapping);}
    }
    static Isolation Protect(Process process,ProcessModule module,IntPtr handle,bool apply)
    {
        long start=process.StartTime.ToUniversalTime().Ticks;
        IntPtr slot=IntPtr.Add(module.BaseAddress,(int)SlotRva);
        CheckFile(module.FileName);
        CheckReader(Read(handle,IntPtr.Add(module.BaseAddress,(int)ReaderRva),Reader.Length));
        IntPtr original=ReadPointer(handle,slot);
        Isolation existing;
        if(Cache.TryGetValue(process.Id,out existing) && existing.Start==start && existing.Module==module.BaseAddress)
        {
            Require(original==existing.Zero && Read(handle,existing.Zero,1)[0]==0,"Isolation pointer changed unexpectedly");
            return existing;
        }
        Require(original!=IntPtr.Zero,"OpenSpeedy initialization has no flag mapping");
        MEMORY_BASIC_INFORMATION info;
        Require(VirtualQueryEx(handle,original,out info,(UIntPtr)Marshal.SizeOf(typeof(MEMORY_BASIC_INFORMATION)))!=UIntPtr.Zero,"Cannot inspect original flag memory");
        Require(info.Type==0x40000,"pEnabled is not the original mapped flag; restart game before starting a new helper");
        Require((Read(handle,original,1)[0]!=0)==ControllerEnabled(process.Id),"Original flag differs from controller mapping");
        var record=new Isolation {Start=start,Module=module.BaseAddress,Slot=slot,Original=original};
        if(!apply)return record;
        record.Zero=Repoint(handle,slot);Cache[process.Id]=record;
        return record;
    }
    static IntPtr Repoint(IntPtr handle,IntPtr slot)
    {
        Require((slot.ToInt64()&7)==0,"Native flag pointer slot is not aligned");
        IntPtr zero=VirtualAllocEx(handle,IntPtr.Zero,(UIntPtr)4096,0x3000,4);
        Require(zero!=IntPtr.Zero,"Cannot allocate target private false flag: "+Marshal.GetLastWin32Error());
        // VirtualAllocEx zero-initializes committed memory. Keep it for target lifetime:
        // freeing it while a native hook reads it would be unsafe, including helper shutdown.
        Require(Read(handle,zero,1)[0]==0,"Target allocation was not zero initialized");
        byte[] pointer=BitConverter.GetBytes(zero.ToInt64()); UIntPtr written;
        bool ok=WriteProcessMemory(handle,slot,pointer,(UIntPtr)8,out written);
        Require(ok && written.ToUInt64()==8 && ReadPointer(handle,slot)==zero,"Cannot repoint native enable slot; stop helper and restart game");
        return zero;
    }
    static T Export<T>(IntPtr module,string name) where T:class
    {
        IntPtr address=GetProcAddress(module,name); Require(address!=IntPtr.Zero,"Missing export "+name);
        return Marshal.GetDelegateForFunctionPointer(address,typeof(T)) as T;
    }
    static void LoadController(string path)
    {
        CheckFile(path); Require(GetModuleHandle("speedpatch64.dll")==IntPtr.Zero,"Helper already has speedpatch loaded unexpectedly");
        Controller=LoadLibrary(path); Require(Controller!=IntPtr.Zero,"Cannot load controller DLL");
        // Loading OpenSpeedy enables its host. Disable this helper immediately, before waits/clocks.
        Disable=Export<NativeDisable>(Controller,"SP_Disable");
        Disable((uint)Process.GetCurrentProcess().Id);
        Require(Export<NativeEnabled>(Controller,"SP_IsEnabled")()==0,"Could not disable native hooks in helper");
        GetSpeed=Export<NativeSpeed>(Controller,"SP_GetSpeed");
    }
    static object Sample(string gameExe,string dll,bool apply)
    {
        var pids=new List<int>(); var details=new List<object>(); var errors=new List<string>(); bool enabled=false; int matched=0;
        foreach(var process in Process.GetProcessesByName(Path.GetFileNameWithoutExtension(gameExe)))
        using(process)
        {
            IntPtr handle=IntPtr.Zero;
            try
            {
                if(!SamePath(process.MainModule.FileName,gameExe))continue;
                matched++;
                // Read the role and modules before requesting mutation rights.
                // A module-enumeration failure propagates; it is never treated as no DLL.
                handle=OpenProcess(0x410,false,(uint)process.Id); Require(handle!=IntPtr.Zero,"OpenProcess failed");
                string commandLine=CommandLine(handle); bool roleEnabled=EnabledRole(commandLine);
                var modules=PatchModules(process);bool bootstrapped=false;
                ModulePlan plan=PlanModules(roleEnabled,modules.Length,apply);
                if(plan==ModulePlan.NativeUnhooked)
                {
                    pids.Add(process.Id);
                    details.Add(new {pid=process.Id,role="utility",controllerEnabled=false,isolated=true,bootstrapInjected=false,nativeUnhooked=true});
                    continue;
                }
                if(apply)
                {
                    IntPtr writer=OpenIsolationHandle(handle,process.Id);
                    CloseHandle(handle);handle=writer;
                }
                if(plan==ModulePlan.Bootstrap){Bootstrap(process,handle,dll);modules=PatchModules(process);bootstrapped=true;}
                Require(modules.Length==1,"speedpatch64.dll is not loaded exactly once");
                Isolation record=Protect(process,modules[0],handle,apply);
                if(bootstrapped)record.BootstrapInjected=true;
                bool flag=ControllerEnabled(process.Id); if(roleEnabled)enabled|=flag;
                if(record.Zero!=IntPtr.Zero)pids.Add(process.Id);
                details.Add(new {pid=process.Id,role=roleEnabled?"main-or-renderer":"utility",controllerEnabled=flag,isolated=record.Zero!=IntPtr.Zero,bootstrapInjected=record.BootstrapInjected,nativeUnhooked=false});
            }
            catch(Exception error){errors.Add("PID "+process.Id+": "+error.Message);}
            finally{if(handle!=IntPtr.Zero)CloseHandle(handle);}
        }
        if(matched==0)errors.Add("No exact-path Sixty Four process found");
        double configured=GetSpeed==null?1:GetSpeed();
        if(double.IsNaN(configured)||double.IsInfinity(configured)||configured<=0){errors.Add("Invalid controller factor");configured=1;}
        bool isolated=apply && matched>0 && errors.Count==0 && pids.Count==matched;
        return new {ok=isolated,clockIsolated=isolated,enabled=enabled,factor=enabled?configured:1,configuredFactor=configured,pids=pids,processes=details,errors=errors,mode=apply?"apply":"inspect"};
    }
    static bool Rejects(Action action){try{action();return false;}catch{return true;}}
    static void SelfTest(string dll)
    {
        int passed=0;
        Action<bool,string> test=(ok,name)=>{Require(ok,"Self-test failed: "+name);passed++;};
        CheckFile(dll); test(true,"real DLL exact SHA256, x64 PE exports and reader slot");
        var bad=(byte[])Reader.Clone(); bad[0]^=1;test(Rejects(()=>CheckReader(bad)),"reject modified reader prefix");
        bad=(byte[])Reader.Clone(); bad[17]^=8;test(Rejects(()=>CheckReader(bad)),"reject mismatched RIP operand");
        test(ReaderRva+12+BitConverter.ToInt32(Reader,7)==SlotRva,"first RIP resolves aligned slot");
        test(ReaderRva+21+BitConverter.ToInt32(Reader,17)==SlotRva,"second RIP resolves same slot");
        test(EnabledRole("game.exe"),"main flag used");
        test(EnabledRole("game.exe --type=renderer --foo"),"renderer flag used");
        test(!EnabledRole("game.exe --type=utility"),"utility flag excluded");
        test(!EnabledRole("game.exe --type=gpu-process"),"GPU flag excluded");
        test(PlanModules(EnabledRole("game.exe"),0,true)==ModulePlan.Bootstrap,"unhooked main must bootstrap");
        test(PlanModules(EnabledRole("game.exe --type=renderer"),0,true)==ModulePlan.Bootstrap,"unhooked renderer must bootstrap");
        test(PlanModules(EnabledRole("game.exe --type=utility --utility-sub-type=audio.mojom.AudioService"),0,true)==ModulePlan.NativeUnhooked,"unhooked audio utility stays native without injection");
        test(PlanModules(EnabledRole("game.exe --type=gpu-process"),0,true)==ModulePlan.NativeUnhooked,"unhooked non-controller child stays native");
        test(PlanModules(false,0,false)==ModulePlan.NativeUnhooked,"read-only inspection accepts native unhooked utility");
        test(PlanModules(false,1,true)==ModulePlan.Protect,"already hooked utility still requires verified protection");
        test(PlanModules(true,1,true)==ModulePlan.Protect,"already hooked main or renderer still requires protection");
        test(PlanModules(false,1,false)==ModulePlan.Inspect,"read-only hooked utility still requires verification");
        test(Rejects(()=>PlanModules(true,0,false)),"inspection cannot silently accept unhooked controller role");
        test(Rejects(()=>PlanModules(false,2,true)),"duplicate utility DLLs fail closed");
        test(Rejects(()=>PlanModules(false,-1,true)),"invalid module count cannot masquerade as unhooked");
        test(Rejects(()=>CheckInstance(100,101)),"different creation times reject PID instance reuse");
        test(Rejects(()=>CreatedAt(IntPtr.Zero)),"invalid identity handle fails closed");
        IntPtr selfReader=OpenProcess(0x410,false,(uint)Process.GetCurrentProcess().Id),selfWriter=IntPtr.Zero;
        Require(selfReader!=IntPtr.Zero,"Cannot open self-test identity reader");
        try
        {
            long created=CreatedAt(selfReader);
            selfWriter=OpenIsolationHandle(selfReader,Process.GetCurrentProcess().Id);
            test(selfWriter!=selfReader && selfWriter!=IntPtr.Zero,"identity fixture obtains a distinct writer while reader stays open");
            test(CreatedAt(selfReader)==created && CreatedAt(selfWriter)==created,"reader and writer retain the same real process creation time");
            test(CreatedAt(GetCurrentProcess())==created,"identity fixture refers only to this helper instance");
            test(Rejects(()=>OpenIsolationHandle(IntPtr.Zero,Process.GetCurrentProcess().Id)),"reader identity failure rejects and closes the new writer");
        }
        finally{if(selfWriter!=IntPtr.Zero)CloseHandle(selfWriter);CloseHandle(selfReader);}
        test(SamePath(@"C:\Games\Sixty Four.exe",@"c:\games\SIXTY FOUR.exe"),"path case normalization");
        test(!SamePath(@"C:\Games\Sixty Four.exe",@"C:\Other\Sixty Four.exe"),"other executable path excluded");
        test(!ShouldDisable(false),"preexisting enabled flag is preserved");
        test(ShouldDisable(true),"new bootstrap flag must be disabled");
        var serialized=Json.Serialize(new {clockIsolated=false,enabled=false,factor=1.0,pids=new int[0]});
        test(serialized.Contains("\"clockIsolated\":false")&&serialized.Contains("\"factor\":1"),"NDJSON serializes numeric effective factor");
        test(GetModuleHandle("speedpatch64.dll")==IntPtr.Zero,"self-test does not load speedpatch");
        // Exercise the actual pointer writer against memory allocated by this fixture
        // in the helper itself. No game process or native speedpatch DLL is involved.
        IntPtr fixtureFlag=Marshal.AllocHGlobal(8),fixtureSlot=Marshal.AllocHGlobal(8),fixtureZero=IntPtr.Zero;
        try
        {
            Marshal.WriteByte(fixtureFlag,1);Marshal.WriteIntPtr(fixtureSlot,fixtureFlag);
            fixtureZero=Repoint(GetCurrentProcess(),fixtureSlot);
            test(Marshal.ReadIntPtr(fixtureSlot)==fixtureZero,"Win32 pointer writer repoints fixture slot");
            test(Marshal.ReadByte(fixtureZero)==0,"new native flag reads false");
            test(Marshal.ReadByte(fixtureFlag)==1,"original enabled mapping preserved true");
            Marshal.WriteByte(fixtureFlag,0);
            test(Marshal.ReadByte(Marshal.ReadIntPtr(fixtureSlot))==0,"controller off leaves native false");
            Marshal.WriteByte(fixtureFlag,1);
            test(Marshal.ReadByte(fixtureFlag)==1&&Marshal.ReadByte(Marshal.ReadIntPtr(fixtureSlot))==0,"controller on remains readable while native false");
            test(Rejects(()=>Repoint(GetCurrentProcess(),IntPtr.Add(fixtureSlot,1))),"unaligned pointer rejected before allocation/write");
        }
        finally
        {
            Marshal.WriteIntPtr(fixtureSlot,fixtureFlag);
            if(fixtureZero!=IntPtr.Zero)VirtualFreeEx(GetCurrentProcess(),fixtureZero,UIntPtr.Zero,0x8000);
            Marshal.FreeHGlobal(fixtureSlot);Marshal.FreeHGlobal(fixtureFlag);
        }
        Console.WriteLine(Json.Serialize(new {selfTest="passed",tests=passed,dllSha256=ExpectedHash,readerRva="0x1170",slotRva="0xa458",externalProcessOpened=false}));
    }
    static int Main(string[] args)
    {
        try
        {
            Require(IntPtr.Size==8,"Build and run helper as x64");
            string game=null,dll=@"C:\Program Files\OpenSpeedy\speedpatch64.dll";bool apply=false,selfTest=false,once=false;int interval=250,parent=0;Process parentProcess=null;
            for(int i=0;i<args.Length;i++)
            {
                if(args[i]=="--game-exe"||args[i]=="--game")game=Path.GetFullPath(args[++i]);
                else if(args[i]=="--speedpatch"||args[i]=="--dll")dll=Path.GetFullPath(args[++i]);
                else if(args[i]=="--apply")apply=true;
                else if(args[i]=="--watch"){}
                else if(args[i]=="--parent")parent=int.Parse(args[++i],CultureInfo.InvariantCulture);
                else if(args[i]=="--self-test")selfTest=true;
                else if(args[i]=="--once")once=true;
                else if(args[i]=="--interval-ms")interval=int.Parse(args[++i],CultureInfo.InvariantCulture);
                else throw new ArgumentException("Unknown option "+args[i]);
            }
            if(selfTest){SelfTest(dll);return 0;}
            Require(game!=null && File.Exists(game),"Provide --game-exe with the exact existing game executable path");
            Require(interval>=50 && interval<=5000,"Interval must be 50..5000 ms");
            Require(!apply || Path.GetFileName(game).Equals("sixtyfour.exe",StringComparison.OrdinalIgnoreCase),"Apply requires the exact sixtyfour.exe executable");
            if(parent!=0){parentProcess=Process.GetProcessById(parent);Require(SamePath(parentProcess.MainModule.FileName,game),"Parent must be the exact game executable");}
            if(apply)LoadController(dll);
            Console.CancelKeyPress+=(sender,e)=>{e.Cancel=true;Stopping=true;};
            do
            {
                if(parentProcess!=null&&parentProcess.HasExited)break;
                Console.WriteLine(Json.Serialize(Sample(game,dll,apply)));Console.Out.Flush();if(!apply||once)break;Thread.Sleep(interval);
            }while(!Stopping);
            if(parentProcess!=null)parentProcess.Dispose();
            return 0;
        }
        catch(Exception error){Console.Error.WriteLine(error.Message);return 1;}
    }
    [StructLayout(LayoutKind.Sequential)] struct MEMORY_BASIC_INFORMATION
    { public IntPtr BaseAddress,AllocationBase;public uint AllocationProtect;public ushort PartitionId;public UIntPtr RegionSize;public uint State,Protect,Type; }
    [DllImport("kernel32.dll",SetLastError=true)] static extern IntPtr OpenProcess(uint access,bool inherit,uint pid);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool GetProcessTimes(IntPtr process,out long creation,out long exit,out long kernel,out long user);
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool ReadProcessMemory(IntPtr process,IntPtr address,[Out]byte[] buffer,UIntPtr count,out UIntPtr read);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool WriteProcessMemory(IntPtr process,IntPtr address,byte[] buffer,UIntPtr count,out UIntPtr written);
    [DllImport("kernel32.dll",SetLastError=true)] static extern IntPtr VirtualAllocEx(IntPtr process,IntPtr address,UIntPtr size,uint allocationType,uint protect);
    [DllImport("kernel32.dll",SetLastError=true)] static extern bool VirtualFreeEx(IntPtr process,IntPtr address,UIntPtr size,uint freeType);
    [DllImport("kernel32.dll",SetLastError=true)] static extern IntPtr CreateRemoteThread(IntPtr process,IntPtr attributes,UIntPtr stackSize,IntPtr start,IntPtr parameter,uint flags,out uint id);
    [DllImport("kernel32.dll",SetLastError=true)] static extern uint WaitForSingleObject(IntPtr handle,uint milliseconds);
    [DllImport("kernel32.dll",SetLastError=true)] static extern UIntPtr VirtualQueryEx(IntPtr process,IntPtr address,out MEMORY_BASIC_INFORMATION info,UIntPtr length);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr OpenFileMapping(uint access,bool inherit,string name);
    [DllImport("kernel32.dll",SetLastError=true)] static extern IntPtr MapViewOfFile(IntPtr mapping,uint access,uint high,uint low,UIntPtr size);
    [DllImport("kernel32.dll")] static extern bool UnmapViewOfFile(IntPtr address);
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr LoadLibrary(string path);
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode)] static extern IntPtr GetModuleHandle(string name);
    [DllImport("kernel32.dll",CharSet=CharSet.Ansi,ExactSpelling=true)] static extern IntPtr GetProcAddress(IntPtr module,string name);
    [DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(IntPtr process,int informationClass,IntPtr information,int length,out int returnLength);
}
