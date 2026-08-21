# RootHide iOS16 Core Final - Audit & Build Plan

## Final Goal

Produce:

RootHide 3.0.7 iOS16 Core Final

Flow:

Source Audit ↓ Final Patch Set ↓ Local/GitHub Actions Build ↓ TIPA ↓
Dopamine iOS16 Device Validation

## Progress

### Step 1/8 Target Definition ✅

Position: - RootHide 3.0.7 - Dopamine iOS16 - iOS16 Core Edition

Not targeting: - iOS17+ - Full system compatibility

Goal: A clean, stable, maintainable iOS16 Core baseline.

------------------------------------------------------------------------

### Step 2/8 Source Baseline ✅

Source evolution:

RC2B ↓ aeb6f21 audit ↓ clean/pre17-aeb6f21 ↓ b8751c2 ↓
roothide-3.0.7-ios16-final

------------------------------------------------------------------------

### Step 3/8 Clean Audit ✅

Removed:

## Credential donor

Removed: - proc_copy_ucred - target_proc_with_ucred -
proc_ucred_update_content - donor transport

Reason: Not part of iOS16 Core and creates coupling between: process /
credential / spawn / dyld.

## Persona systemwide fix

Removed: - JBS_SYSTEMWIDE_PERSONA_FIX - jbclient_persona_fix -
systemwide_persona_fix

Reason: Special mechanism, not Core.

## TXM post-fork

Removed: - txm_fork_fix - parent/child pmap post-fork path

Reason: Special runtime workaround.

------------------------------------------------------------------------

### Step 4/8 Version Difference Audit ✅

Classification:

KEEP: - Core runtime

ISOLATE: - Manager layer - Application layer

REMOVE: - Historical special paths

------------------------------------------------------------------------

### Step 5/8 Final Modification List ✅

## KEEP_LIST

Core:

-   Process Runtime
-   Injection Runtime
-   Systemhook
-   Trust Layer

Important components:

-   jbdSpawnPatchChild
-   jbdSpawnPatchChildEx
-   roothide_patch_proc_ex
-   forceDyldPatch
-   dyldhook
-   systemhook.dylib
-   trustcache
-   signature handling

## REMOVE_LIST

Do not restore:

-   credential donor
-   persona systemwide fix
-   TXM workaround

## ISOLATE_LIST

Keep outside Core:

-   mount management
-   bootstrap management
-   UI enhancements
-   status display

------------------------------------------------------------------------

### Step 6/8 Source Modification Plan ✅

Rule:

Removal must complete:

Function ↓ Call ↓ Declaration ↓ Residual reference

Do not continue cleaning Core.

------------------------------------------------------------------------

# Step 7/8 Build

Current build flow:

Source ↓ GitHub Actions / Local Build ↓ Artifact ↓ TIPA

Build checks:

-   undefined symbol
-   missing header
-   link failure
-   entitlement error
-   package error

------------------------------------------------------------------------

# Step 8/8 Final Validation

Target:

RootHide_3.0.7_iOS16_Core_Final.tipa

Validation:

-   Dopamine iOS16 installation
-   jailbreak flow
-   injection
-   RootHide runtime
-   stability

------------------------------------------------------------------------

# GitHub Actions Next

Recommended repository structure:

.github/ workflows/ build.yml

Build workflow should:

1.  Checkout source
2.  Install dependencies
3.  Build RootHide
4.  Package TIPA
5.  Upload artifact
