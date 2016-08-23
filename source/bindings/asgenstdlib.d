/* This was taken from <https://github.com/dlang/druntime/commit/c59ecbe27b4da4366c7cb8bce4adf0fefe48c9fb>
 */

////////////////////////////////////////////////////////////////////////// //
// C API

module bindings.asgenstdilb;

extern(C):
nothrow:
@nogc:

char* mkdtemp(char*); // Defined in IEEE 1003.1, 2008 Edition
