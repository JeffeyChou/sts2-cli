#!/bin/bash
# setup.sh — Copy game DLLs from Steam installation to lib/
#
# Prerequisites:
#   - Slay the Spire 2 installed via Steam
#   - .NET 9+ SDK (ARM64 for Apple Silicon, x64 for Intel/Linux)
#
# Usage:
#   ./setup.sh                    # Auto-detect Steam path
#   ./setup.sh /path/to/game      # Manual game directory

set -eo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Resolve a supplied relative game directory before changing directory.
GAME_DIR="${1:-${STS2_GAME_DIR:-}}"
if [ -n "$GAME_DIR" ]; then
    GAME_DIR="$(cd "$GAME_DIR" && pwd)"
fi
cd "$REPO_DIR"

# ── Locate game directory ──


if [ -z "$GAME_DIR" ]; then
    # Auto-detect based on platform
    case "$(uname -s)" in
        Darwin)
            GAME_DIR="$HOME/Library/Application Support/Steam/steamapps/common/Slay the Spire 2/SlayTheSpire2.app/Contents/Resources/data_sts2_macos_arm64"
            if [ ! -d "$GAME_DIR" ]; then
                # Try x86_64
                GAME_DIR="$HOME/Library/Application Support/Steam/steamapps/common/Slay the Spire 2/SlayTheSpire2.app/Contents/Resources/data_sts2_macos_x86_64"
            fi
            ;;
        Linux)
            GAME_DIR="$HOME/.steam/steam/steamapps/common/Slay the Spire 2"
            if [ ! -d "$GAME_DIR" ]; then
                GAME_DIR="$HOME/.local/share/Steam/steamapps/common/Slay the Spire 2"
            fi
            ;;
        MINGW*|MSYS*|CYGWIN*)
            GAME_DIR="C:/Program Files (x86)/Steam/steamapps/common/Slay the Spire 2"
            ;;
    esac
fi

if [ ! -d "$GAME_DIR" ]; then
    echo "❌ Game directory not found: $GAME_DIR"
    echo ""
    echo "Usage: ./setup.sh /path/to/game/data"
    echo ""
    echo "On macOS, this is usually:"
    echo "  ~/Library/Application Support/Steam/steamapps/common/Slay the Spire 2/SlayTheSpire2.app/Contents/Resources/data_sts2_macos_arm64"
    exit 1
fi

echo "📁 Game directory: $GAME_DIR"

# ── Copy DLLs ──

mkdir -p lib

DLLS=(
    "sts2.dll"
    "SmartFormat.dll"
    "SmartFormat.ZString.dll"
    "Sentry.dll"
    "Sentry.Godot.dll"
    "Steamworks.NET.dll"
    "MonoMod.Backports.dll"
    "MonoMod.ILHelpers.dll"
    "0Harmony.dll"
    "System.IO.Hashing.dll"
)

echo ""
echo "📦 Copying DLLs to lib/..."
for dll in "${DLLS[@]}"; do
    src="$GAME_DIR/$dll"
    if [ -f "$src" ]; then
        cp "$src" "lib/$dll"
        echo "  ✓ $dll"
    else
        echo "  ✗ $dll not found at $src"
        # Try searching subdirectories
        found=$(find "$GAME_DIR" -name "$dll" -print -quit 2>/dev/null)
        if [ -n "$found" ]; then
            cp "$found" "lib/$dll"
            echo "    → found at $found"
        else
            echo "    ⚠ Skipped (may cause build errors)"
        fi
    fi
done

# Back up original sts2.dll
if [ -f "lib/sts2.dll" ]; then
    cp "lib/sts2.dll" "lib/sts2.dll.original"
    echo "  ✓ Backed up sts2.dll.original"
fi

# Refresh text alongside the engine so descriptions match the installed balance.
PCK_PATH="$(find "$GAME_DIR" "$(dirname "$GAME_DIR")" -maxdepth 2 -name '*.pck' -print -quit 2>/dev/null)"
if [ -n "$PCK_PATH" ]; then
    python3 scripts/extract_localization.py "$PCK_PATH"
else
    echo "⚠ No game PCK found; keeping existing localization tables."
fi

# ── Detect .NET SDK ──

DOTNET=""
if [ -x "$HOME/.dotnet-arm64/dotnet" ]; then
    DOTNET="$HOME/.dotnet-arm64/dotnet"
elif command -v dotnet &>/dev/null; then
    DOTNET="dotnet"
fi

if [ -z "$DOTNET" ]; then
    echo ""
    echo "❌ .NET SDK not found."
    echo "   Install .NET 9+ from https://dotnet.microsoft.com/download"
    echo "   Or set DOTNET env var to your dotnet binary path."
    exit 1
fi

echo ""
echo "🔧 .NET SDK: $DOTNET ($($DOTNET --version))"

# ── IL Patch sts2.dll ──

echo ""
echo "🔨 Applying IL patches to sts2.dll..."

# Create a temporary patching project
PATCH_DIR=$(mktemp -d)
cat > "$PATCH_DIR/Patcher.csproj" << 'PROJ'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net9.0</TargetFramework>
  </PropertyGroup>
  <ItemGroup>
    <PackageReference Include="Mono.Cecil" Version="0.11.6" />
  </ItemGroup>
</Project>
PROJ

cat > "$PATCH_DIR/Program.cs" << 'CSHARP'
using System;
using System.IO;
using Mono.Cecil;
using Mono.Cecil.Cil;
using System.Collections.Generic;
using System.Linq;

var dllPath = args[0];
Console.WriteLine($"Patching {dllPath}...");

var resolver = new DefaultAssemblyResolver();
var libDir = Path.GetDirectoryName(dllPath)!;
resolver.AddSearchDirectory(libDir);
// Also search for GodotSharp.dll in the GodotStubs output (fallback)
var stubsDir = Path.Combine(Path.GetDirectoryName(libDir)!, "src", "GodotStubs", "bin", "Debug", "net9.0");
if (Directory.Exists(stubsDir)) resolver.AddSearchDirectory(stubsDir);
var module = ModuleDefinition.ReadModule(dllPath, new ReaderParameters {
    AssemblyResolver = resolver,
    ReadingMode = ReadingMode.Deferred  // Don't force-resolve all references upfront
});

int patches = 0;

// Patch 1: Task.Yield() — make YieldAwaitable.YieldAwaiter.IsCompleted return true
// This prevents async deadlocks in headless mode
foreach (var type in module.Types)
{
    foreach (var nested in type.NestedTypes)
    {
        foreach (var nested2 in nested.NestedTypes)
        {
            if (nested2.Name.Contains("YieldAwaiter") || nested2.Name == "<>c")
            {
                foreach (var method in nested2.Methods)
                {
                    if (method.Name == "get_IsCompleted" && method.Body != null)
                    {
                        var il = method.Body.GetILProcessor();
                        il.Body.Instructions.Clear();
                        il.Emit(OpCodes.Ldc_I4_1);
                        il.Emit(OpCodes.Ret);
                        patches++;
                        Console.WriteLine($"  Patched {type.Name}.{nested.Name}.{nested2.Name}.IsCompleted");
                    }
                }
            }
        }
    }
}

// Patch 2: WaitUntilQueueIsEmptyOrWaitingOnNonPlayerDrivenAction → return Task.CompletedTask
foreach (var type in module.Types)
{
    foreach (var method in type.Methods)
    {
        if (method.Name == "WaitUntilQueueIsEmptyOrWaitingOnNonPlayerDrivenAction" && method.Body != null)
        {
            var il = method.Body.GetILProcessor();
            il.Body.Instructions.Clear();
            // return Task.CompletedTask
            var taskType = module.ImportReference(typeof(System.Threading.Tasks.Task));
            var completedProp = module.ImportReference(
                typeof(System.Threading.Tasks.Task).GetProperty("CompletedTask")!.GetGetMethod()!);
            il.Emit(OpCodes.Call, completedProp);
            il.Emit(OpCodes.Ret);
            patches++;
            Console.WriteLine($"  Patched {type.Name}.{method.Name} → Task.CompletedTask");
        }
    }
}

// Patch 3: NDebugAudioManager sound methods -> no-ops. Instance is null headless and several
// gameplay paths (Dig rest option, Jungle Maze Adventure, Dense Vegetation, Doll Room) call
// Instance.Play() unguarded; the runtime side returns an inert Instance (RunSimulator.PatchDebugAudio).
foreach (var type in module.Types)
{
    if (type.FullName != "MegaCrit.Sts2.Core.Audio.Debug.NDebugAudioManager") continue;
    foreach (var method in type.Methods)
    {
        if (method.Body == null || method.IsStatic || method.IsConstructor) continue;
        if (method.Name != "Play" && !method.Name.StartsWith("Stop") && !method.Name.EndsWith("AudioVolume")) continue;
        if (method.ReturnType.MetadataType != MetadataType.Void && method.ReturnType.MetadataType != MetadataType.Int32) continue;
        var il = method.Body.GetILProcessor();
        il.Body.Instructions.Clear();
        il.Body.ExceptionHandlers.Clear();
        il.Body.Variables.Clear();
        if (method.ReturnType.MetadataType == MetadataType.Int32) il.Emit(OpCodes.Ldc_I4_0);
        il.Emit(OpCodes.Ret);
        patches++;
        Console.WriteLine($"  Patched {type.Name}.{method.Name} -> no-op");
    }
}

// Patch 4: gameplay code (events like Dense Vegetation, Punch Off, Amalgamator) calls
// NGame.Instance.ScreenShake*/ScreenRumble unguarded; NGame.Instance is null headless, so the
// event option throws and silently never completes. Replace those void calls with pops of the
// receiver and arguments. UI node code (MegaCrit.Sts2.Core.Nodes.*) is left untouched.
var removeCalls = new Dictionary<string, HashSet<string>> {
    ["NGame"] = new() { "ScreenShake", "ScreenRumble", "ScreenShakeTrauma" },
    // NAudioManager.Instance is null headless; Kaiser Crab's BeforeDeath calls it unguarded.
    ["NAudioManager"] = new() { "PlayOneShot" },
};
IEnumerable<TypeDefinition> AllTypes(IEnumerable<TypeDefinition> ts) { foreach (var t in ts) { yield return t; foreach (var n in AllTypes(t.NestedTypes)) yield return n; } }
foreach (var type in AllTypes(module.Types))
{
    if (type.Namespace.StartsWith("MegaCrit.Sts2.Core.Nodes") || (type.DeclaringType?.Namespace ?? "").StartsWith("MegaCrit.Sts2.Core.Nodes")) continue;
    foreach (var method in type.Methods)
    {
        if (method.Body == null) continue;
        var ins = method.Body.Instructions;
        for (int k = 0; k < ins.Count; k++)
        {
            if ((ins[k].OpCode == OpCodes.Callvirt || ins[k].OpCode == OpCodes.Call) && ins[k].Operand is MethodReference mr
                && removeCalls.TryGetValue(mr.DeclaringType.Name, out var names) && names.Contains(mr.Name)
                && mr.ReturnType.MetadataType == MetadataType.Void)
            {
                int pops = mr.Parameters.Count + 1;
                ins[k].OpCode = OpCodes.Pop; ins[k].Operand = null;
                for (int q = 1; q < pops; q++) ins.Insert(k + 1, Instruction.Create(OpCodes.Pop));
                patches++;
                Console.WriteLine($"  Patched {type.FullName}.{method.Name}: {mr.DeclaringType.Name}.{mr.Name} -> pop x{pops}");
            }
        }
    }
}

// Patch 5: monsters whose moves drive a combat-room background node (Kaiser Crab: Crusher/Rocket).
// Their Background getter throws without NCombatRoom, which aborted every move before its damage.
// The getter now returns an inert instance and the node's animation methods are no-ops.
var getUninit = module.ImportReference(typeof(System.Runtime.CompilerServices.RuntimeHelpers).GetMethod("GetUninitializedObject")!);
var getTypeFromHandle = module.ImportReference(typeof(Type).GetMethod("GetTypeFromHandle")!);
var completedTask = module.ImportReference(typeof(System.Threading.Tasks.Task).GetProperty("CompletedTask")!.GetGetMethod()!);
var inertNodeTypes = new HashSet<string>();
foreach (var type in module.Types)
{
    if (type.Namespace != "MegaCrit.Sts2.Core.Models.Monsters") continue;
    foreach (var method in type.Methods)
    {
        if (method.Name != "get_Background" || method.Body == null) continue;
        var rt = method.ReturnType.Resolve();
        if (rt == null || !rt.Namespace.StartsWith("MegaCrit.Sts2.Core.Nodes")) continue;
        var il = method.Body.GetILProcessor();
        il.Body.Instructions.Clear(); il.Body.ExceptionHandlers.Clear(); il.Body.Variables.Clear();
        il.Emit(OpCodes.Ldtoken, method.ReturnType);
        il.Emit(OpCodes.Call, getTypeFromHandle);
        il.Emit(OpCodes.Call, getUninit);
        il.Emit(OpCodes.Castclass, method.ReturnType);
        il.Emit(OpCodes.Ret);
        inertNodeTypes.Add(rt.FullName);
        patches++;
        Console.WriteLine($"  Patched {type.Name}.get_Background -> inert {rt.Name}");
    }
}
foreach (var type in module.Types)
{
    if (!inertNodeTypes.Contains(type.FullName)) continue;
    foreach (var method in type.Methods)
    {
        if (method.Body == null || method.IsStatic || method.IsConstructor || !method.IsPublic) continue;
        bool isVoid = method.ReturnType.MetadataType == MetadataType.Void;
        bool isTask = method.ReturnType.FullName == "System.Threading.Tasks.Task";
        if (!isVoid && !isTask) continue;
        var il = method.Body.GetILProcessor();
        il.Body.Instructions.Clear(); il.Body.ExceptionHandlers.Clear(); il.Body.Variables.Clear();
        if (isTask) il.Emit(OpCodes.Call, completedTask);
        il.Emit(OpCodes.Ret);
        patches++;
        Console.WriteLine($"  Patched {type.Name}.{method.Name} -> no-op");
    }
}

// Patch 6: event models (Models.Events.*) drive event-room UI nodes directly, e.g. The Trial's Accept
// starts with NEventRoom.Instance.Layout.RemoveNodesOnPortrait(); with no UI the NRE aborted the option.
// In event code, calls to UI node types (MegaCrit.Sts2.Core.Nodes.*) become stack-neutral no-ops:
// void -> pop receiver+args; reference-returning -> pop receiver+args, push null (so chains go null).
// Static UI calls are handled the same way. Value-returning calls are left untouched.
int uiSites = 0;
foreach (var type in AllTypes(module.Types))
{
    var ns = type.DeclaringType?.Namespace ?? type.Namespace;
    for (var dt = type.DeclaringType; dt != null; dt = dt.DeclaringType) ns = dt.Namespace;
    if (ns != "MegaCrit.Sts2.Core.Models.Events") continue;
    foreach (var method in type.Methods)
    {
        if (method.Body == null) continue;
        var ins = method.Body.Instructions;
        for (int k = 0; k < ins.Count; k++)
        {
            if ((ins[k].OpCode != OpCodes.Callvirt && ins[k].OpCode != OpCodes.Call) || ins[k].Operand is not MethodReference mr) continue;
            var declNs = mr.DeclaringType.Namespace;
            for (var d = mr.DeclaringType.DeclaringType; d != null; d = d.DeclaringType) declNs = d.Namespace;
            bool uiNode = declNs.StartsWith("MegaCrit.Sts2.Core.Nodes");
            // Godot scene-graph classes (PackedScene.Instantiate, Node2D.set_Position, ...); structs like Vector2 stay
            bool godotRef = declNs == "Godot" && !mr.DeclaringType.IsValueType && mr.DeclaringType.Resolve()?.IsValueType == false;
            if (!uiNode && !godotRef) continue;
            if (mr.Name == "get_Instance") continue;  // keep the (null) singleton load; its uses are neutralized
            var ret = mr.ReturnType;
            if (ret.IsGenericParameter && mr is GenericInstanceMethod gim && gim.GenericArguments.Count == 1)
                ret = gim.GenericArguments[0];  // e.g. PackedScene.Instantiate<Node2D>() -> Node2D
            bool isVoid = ret.MetadataType == MetadataType.Void;
            bool isRef = !isVoid && !ret.IsValueType && !ret.IsGenericParameter && ret.Resolve()?.IsValueType != true;
            if (!isVoid && !isRef) continue;
            int pops = mr.Parameters.Count + (mr.HasThis ? 1 : 0);
            var first = ins[k];
            if (pops == 0) { first.OpCode = OpCodes.Nop; first.Operand = null; }
            else { first.OpCode = OpCodes.Pop; first.Operand = null; }
            int at = k + 1;
            for (int q = 1; q < pops; q++) ins.Insert(at++, Instruction.Create(OpCodes.Pop));
            if (isRef) ins.Insert(at++, Instruction.Create(OpCodes.Ldnull));
            uiSites++;
            if (uiSites <= 400) Console.WriteLine($"  Patched {type.FullName}.{method.Name}: UI call {mr.DeclaringType.Name}.{mr.Name}");
        }
    }
}
patches += uiSites;

// The Windows build marks pure-IL sts2.dll as x64-only; mark AnyCPU so arm64 hosts can load it.
if (module.Architecture != TargetArchitecture.I386 && module.Attributes.HasFlag(ModuleAttributes.ILOnly))
{
    module.Architecture = TargetArchitecture.I386;
    module.Attributes &= ~(ModuleAttributes.Required32Bit | ModuleAttributes.Preferred32Bit);
    Console.WriteLine($"  Marked {Path.GetFileName(dllPath)} AnyCPU");
}

Console.WriteLine($"Applied {patches} patches");
var outPath = dllPath + ".patched";
module.Write(outPath);
module.Dispose();
File.Delete(dllPath);
File.Move(outPath, dllPath);
Console.WriteLine("Done!");
CSHARP

REPO_DIR="$(pwd)"
cd "$PATCH_DIR"
$DOTNET run -- "$REPO_DIR/lib/sts2.dll" 2>&1
# Steamworks.NET.dll from the Windows build is also x64-only; the patcher marks it AnyCPU.
[ -f "$REPO_DIR/lib/Steamworks.NET.dll" ] && $DOTNET run -- "$REPO_DIR/lib/Steamworks.NET.dll" 2>&1
cd "$REPO_DIR"
rm -rf "$PATCH_DIR"

# ── Build ──

echo ""
echo "🏗️ Building..."
$DOTNET build src/Sts2Headless/Sts2Headless.csproj 2>&1 | tail -5

echo ""
echo "✅ Setup complete!"
echo ""
echo "To play:"
echo "  python3 python/play.py"
echo ""
echo "To run batch games:"
echo "  python3 python/play_full_run.py 10"
