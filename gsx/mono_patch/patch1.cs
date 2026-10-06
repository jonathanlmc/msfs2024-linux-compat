using System;
using System.Linq;
using Mono.Cecil;
using Mono.Cecil.Cil;
class Patch1 {
 static void Main(string[] args) {
  var asm = AssemblyDefinition.ReadAssembly(args[0]);
  var mod = asm.MainModule;

  // Wine Mono crash: Evidence.GetDefaultHostEvidence -> X509Certificate.CreateFromSignedFile
  // -> MonoIO.Read on a bad handle (the running exe is re-opened for its signature).
  // Neutralize by returning the freshly-created empty Evidence: replace the instruction
  // right after `newobj Evidence..ctor` with `ret`. Same byte length as the original
  // ldloc_0, so the rest of the body survives as dead code and the file layout is
  // unchanged (matches the hand byte-patch that was proven to work).
  var ev = mod.GetType("System.Security.Policy.Evidence");
  var gdhe = ev.Methods.Single(m => m.Name == "GetDefaultHostEvidence");
  var gil = gdhe.Body.GetILProcessor();

  if (gdhe.Body.Instructions.Count > 1 && gdhe.Body.Instructions[1].OpCode != OpCodes.Ret) {
   gil.Replace(gdhe.Body.Instructions[1], gil.Create(OpCodes.Ret));
   Console.WriteLine("PATCH GetDefaultHostEvidence");
  }

  var type = mod.GetType("System.Runtime.InteropServices.RegistrationServices");
  if (type == null) { Console.WriteLine("TYPE MISSING"); return; }
  var attr = MethodAttributes.Public | MethodAttributes.HideBySig;

  string[][] pairs = new string[2][];
  pairs[0] = new string[] { "IsAssemblyRegistered", "System.Reflection.Assembly" };
  pairs[1] = new string[] { "IsTypeRegistered", "System.Type" };

  foreach (string[] pair in pairs) {
   if (type.Methods.Any(mm => mm.Name == pair[0])) { Console.WriteLine("SKIP " + pair[0]); continue; }
   MethodDefinition m = new MethodDefinition(pair[0], attr, mod.TypeSystem.Boolean);
   m.Parameters.Add(new ParameterDefinition("target", ParameterAttributes.None, mod.GetType(pair[1])));
   var il = m.Body.GetILProcessor();
   il.Append(il.Create(OpCodes.Ldc_I4_1));
   il.Append(il.Create(OpCodes.Ret));
   type.Methods.Add(m);
   Console.WriteLine("ADDED " + pair[0]);
  }

  asm.Write(args[1]);
  Console.WriteLine("WROTE " + args[1]);
 }
}
