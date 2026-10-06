using System;
using System.Collections.Generic;
using System.Reflection;
using System.Runtime.InteropServices;
using Microsoft.Win32;

public static class WineCompat {
 // Output of RegisterTypeForComClients; patch2 copies it into the caller's Guid&.
 public static Guid LastGuid;

 // regasm's fixed InprocServer32 host and .NET Framework 4 runtime stamp.
 const string InprocServer = "mscoree.dll";
 const string RuntimeVersion = "v4.0.30319";

 // ComVisibleAttribute stores its flag differently across runtimes (an
 // IsVisible/Visible property or a private bool field); probe all, default visible.
 static bool Vis(object attr) {
  PropertyInfo p = attr.GetType().GetProperty("IsVisible");
  if (p == null) p = attr.GetType().GetProperty("Visible");
  if (p != null) return (bool)p.GetValue(attr, null);
  foreach (FieldInfo f in attr.GetType().GetFields(BindingFlags.Instance | BindingFlags.NonPublic | BindingFlags.Public))
   if (f.FieldType == typeof(bool)) return (bool)f.GetValue(attr);
  return true;
 }

 public static IEnumerable<Type> Registrable(Assembly asm) {
  object[] aa = asm.GetCustomAttributes(typeof(ComVisibleAttribute), false);
  bool asmVisible = aa.Length > 0 && Vis(aa[0]);
  Type[] types;
  try { types = asm.GetTypes(); }
  catch (ReflectionTypeLoadException e) { types = Array.FindAll(e.Types, delegate(Type t) { return t != null; }); }

  // regasm's COM-visibility rules for registerable types.
  foreach (Type t in types) {
   if (t == null) continue;
   if (!t.IsPublic && !t.IsNestedPublic) continue;
   if (t.IsAbstract || t.IsInterface || t.IsValueType || t.IsGenericTypeDefinition) continue;
   if (t.GetConstructor(Type.EmptyTypes) == null) continue;
   bool vis = asmVisible;
   object[] ta = t.GetCustomAttributes(typeof(ComVisibleAttribute), false);
   if (ta.Length > 0) vis = Vis(ta[0]);
   if (vis) yield return t;
  }
 }

 public static bool RegisterAssembly(Assembly asm) {
  foreach (Type t in Registrable(asm)) RegisterType(t);
  return true;
 }

 public static void RegisterType(Type t) {
  Guid g = t.GUID;
  LastGuid = g;
  string gs = "{" + g.ToString().ToUpper() + "}";
  string codebase = "file:///" + (t.Assembly.CodeBase ?? "").Replace("\\", "/");

  RegistryKey clsid = Registry.ClassesRoot.CreateSubKey("CLSID\\" + gs);
  if (clsid == null) return;
  clsid.SetValue(null, t.FullName);
  RegistryKey inproc = clsid.CreateSubKey("InprocServer32");
  inproc.SetValue(null, InprocServer);
  inproc.SetValue("ThreadingModel", "Both");
  clsid.CreateSubKey("Assembly").SetValue(null, t.Assembly.FullName);
  clsid.CreateSubKey("RuntimeVersion").SetValue(null, RuntimeVersion);
  clsid.CreateSubKey("CodeBase").SetValue(null, codebase);

  string progid = t.FullName; // regasm fallback when no ProgIdAttribute is present
  clsid.CreateSubKey("ProgId").SetValue(null, progid);
  RegistryKey pk = Registry.ClassesRoot.CreateSubKey(progid);
  pk.SetValue(null, t.FullName);
  pk.CreateSubKey("CLSID").SetValue(null, gs);
 }
}
