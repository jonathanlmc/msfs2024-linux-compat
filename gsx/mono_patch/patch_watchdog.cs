using System;
using System.Linq;
using Mono.Cecil;
using Mono.Cecil.Cil;

// Neutralizes the couatl64_boot.exe watchdog hang-kill under Wine.
//
// Two transformations, both idempotent (re-running on a patched binary
// reports NOTHING PATCHED):
//   1. `Ldc_R8 60000` hang thresholds -> 300000ms (DoMonitor +
//      MonitorAndRestoreFocus).
//   2. `Callvirt Process::get_Responding` -> `Ldc_I4_1`. Under Wine Mono,
//      Responding reads false for the Couatl engine even while its wx
//      MainLoop runs normally, so the notRespondingSince timer arms at
//      startup and force-kills the engine mid-load every session (a healthy
//      Windows load itself takes ~118s). With the call forced true the kill
//      timer can never arm; process-exit and closed-by-user handling are
//      untouched.
//
// Build/run (apply.sh compiles + runs this inside the prefix with the
// prefix's csc.exe and wine-mono's Mono.Cecil; equivalently, any host mono:
//   csc -r:<Mono.Cecil.dll> patch_watchdog.cs -out:patch_watchdog.exe
//   MONO_PATH=<dir of Mono.Cecil.dll> mono patch_watchdog.exe in.exe out.exe)
class PatchWatchdog {
 static void Main(string[] args) {
  if (args.Length < 2) { Console.WriteLine("usage: patch_watchdog.exe <in.exe> <out.exe>"); return; }
  var asm = AssemblyDefinition.ReadAssembly(args[0]);
  var mod = asm.MainModule;
 int patched = 0;

 // The shipped watchdog's hang-kill threshold (ms) and the replacement:
 // 300000 comfortably exceeds a healthy full load (~118s on Windows).
 const double OriginalThresholdMs = 60000.0;
 const double PatchedThresholdMs = 300000.0;

  foreach (var t in mod.GetTypes())
   foreach (var m in t.Methods) {
    if (!m.HasBody) continue;
    var il = m.Body.GetILProcessor();
    foreach (var i in m.Body.Instructions.ToList()) {
     if (i.OpCode.Code == Code.Ldc_R8 && (double)i.Operand == OriginalThresholdMs) {
      il.Replace(i, il.Create(OpCodes.Ldc_R8, PatchedThresholdMs));
      Console.WriteLine("PATCH threshold " + OriginalThresholdMs + " -> " + PatchedThresholdMs + " in " + t.FullName + "::" + m.Name);
      patched++;
     }
     if (i.OpCode.Code == Code.Callvirt &&
         i.Operand is MethodReference mr && mr.Name == "get_Responding") {
      il.Replace(i, il.Create(OpCodes.Ldc_I4_1));
      Console.WriteLine("PATCH get_Responding -> true in " + t.FullName + "::" + m.Name);
      patched++;
     }
    }
   }

  if (patched == 0) { Console.WriteLine("NOTHING PATCHED"); return; }
  asm.Write(args[1]);
  Console.WriteLine("wrote " + args[1]);
 }
}
