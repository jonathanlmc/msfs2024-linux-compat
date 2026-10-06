using System;
using System.Linq;
using Mono.Cecil;
using Mono.Cecil.Cil;
class Patch2 {
 static void Main(string[] args) {
  var wc = AssemblyDefinition.ReadAssembly(args[1]);
  var wcm = wc.MainModule;

  var asm = AssemblyDefinition.ReadAssembly(args[0]);
  var mod = asm.MainModule;
  var type = mod.GetType("System.Runtime.InteropServices.RegistrationServices");

  var wct = wcm.GetType("WineCompat");
  MethodDefinition mRegistrable = null, mRegisterAssembly = null, mRegisterType = null;
  FieldDefinition fLastGuid = null;
  foreach (var m in wct.Methods) {
   if (m.Name == "Registrable") mRegistrable = m;
   if (m.Name == "RegisterAssembly") mRegisterAssembly = m;
   if (m.Name == "RegisterType") mRegisterType = m;
  }
  foreach (var f in wct.Fields)
   if (f.Name == "LastGuid") fLastGuid = f;

  var rRegistrable = mod.ImportReference(mRegistrable);
  var rRegisterAssembly = mod.ImportReference(mRegisterAssembly);
  var rRegisterType = mod.ImportReference(mRegisterType);
  var rLastGuid = mod.ImportReference(fLastGuid);
  var ienum = mod.GetType("System.Collections.Generic.IEnumerable`1");
  var getEnum = ienum.Methods.Single(m => m.Name == "GetEnumerator");
  var tGuid = mod.GetType("System.Guid");

  // Instance methods: arg0 is `this`, so arg1 is the first declared parameter.
  // Parameter counts disambiguate the overloads (Wine Mono ships several).
  foreach (var m in type.Methods.ToList()) {
   if (m.Name == "GetRegistrableTypesInAssembly" && m.Parameters.Count == 1) {
    RewriteBody(m, delegate(ILProcessor il) {
     il.Append(il.Create(OpCodes.Ldarg_1));
     il.Append(il.Create(OpCodes.Call, rRegistrable));
     il.Append(il.Create(OpCodes.Callvirt, getEnum));
     il.Append(il.Create(OpCodes.Ret));
    });
    Console.WriteLine("PATCH GetRegistrableTypesInAssembly");
   }
   if (m.Name == "RegisterAssembly" && m.Parameters.Count == 2) {
    RewriteBody(m, delegate(ILProcessor il) {
     il.Append(il.Create(OpCodes.Ldarg_1));
     il.Append(il.Create(OpCodes.Call, rRegisterAssembly));
     il.Append(il.Create(OpCodes.Ret));
    });
    Console.WriteLine("PATCH RegisterAssembly");
   }
   if (m.Name == "RegisterTypeForComClients" && m.Parameters.Count == 2) {
    RewriteBody(m, delegate(ILProcessor il) {
     il.Append(il.Create(OpCodes.Ldarg_1));
     il.Append(il.Create(OpCodes.Call, rRegisterType));
     il.Append(il.Create(OpCodes.Ldarg_2));
     il.Append(il.Create(OpCodes.Ldsfld, rLastGuid));
     il.Append(il.Create(OpCodes.Stobj, tGuid));
     il.Append(il.Create(OpCodes.Ret));
    });
    Console.WriteLine("PATCH RegisterTypeForComClients(Type,Guid&)");
   }
   if (m.Name == "UnregisterAssembly") {
    RewriteBody(m, delegate(ILProcessor il) {
     il.Append(il.Create(OpCodes.Ldc_I4_1));
     il.Append(il.Create(OpCodes.Ret));
    });
    Console.WriteLine("PATCH UnregisterAssembly");
   }
  }

  // add missing 1-arg RegisterTypeForComClients(Type)
  if (!type.Methods.Any(m => m.Name == "RegisterTypeForComClients" && m.Parameters.Count == 1)) {
   var m = new MethodDefinition("RegisterTypeForComClients", MethodAttributes.Public | MethodAttributes.HideBySig, mod.TypeSystem.Void);
   m.Parameters.Add(new ParameterDefinition("type", ParameterAttributes.None, mod.GetType("System.Type")));
   var il = m.Body.GetILProcessor();
   il.Append(il.Create(OpCodes.Ldarg_1));
   il.Append(il.Create(OpCodes.Call, rRegisterType));
   il.Append(il.Create(OpCodes.Ret));
   type.Methods.Add(m);
   Console.WriteLine("ADD RegisterTypeForComClients(Type)");
  }

  asm.Write(args[2]);
  Console.WriteLine("WROTE " + args[2]);
 }

 static void RewriteBody(MethodDefinition m, Action<ILProcessor> body) {
  var il = m.Body.GetILProcessor();
  while (il.Body.Instructions.Count > 0) il.Remove(il.Body.Instructions[0]);
  m.Body.Variables.Clear();
  m.Body.ExceptionHandlers.Clear();

  body(il);
 }
}
