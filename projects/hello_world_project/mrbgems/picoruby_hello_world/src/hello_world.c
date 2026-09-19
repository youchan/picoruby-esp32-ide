/* VM(mruby/mrubyc)ごとに実装を分けるディスパッチャ。
   picoruby-base64等、picoruby本体のgemと同じ構成(src/<vm>/以下に実体を置き、
   ビルド時に定義されるPICORB_VM_MRUBY/PICORB_VM_MRUBYCで切り替える)。 */

#if defined(PICORB_VM_MRUBY)

#include "mruby/hello_world.c"

#elif defined(PICORB_VM_MRUBYC)

#include "mrubyc/hello_world.c"

#endif
