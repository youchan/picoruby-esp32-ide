/* femtoruby(mrubyc VM)ビルド向け。
   picoruby-require gem(mrbgems/picoruby-require/mrbgem.rake の collect_gems)が
   gem名から自動計算する初期化関数名に合わせる必要がある:
   "picoruby-hello_world" -> "mrbc_hello_world_init"
   (gem名先頭の"picoruby-"を除いた残り("hello_world")の前後に mrbc_ / _init を付けたもの)。 */
#include <stdio.h>
#include <mrubyc.h>

/* Ruby側のHelloWorld#greetから呼ばれる。挨拶文の組み立て自体をC側でやることで、
   「greetがCのコードを呼ぶ」実装例にしてある(mruby版と同じ役割)。 */
static void
c_hello_world_c_greet(mrbc_vm *vm, mrbc_value *v, int argc)
{
  mrbc_value name = GET_ARG(1);
  if (name.tt != MRBC_TT_STRING) {
    mrbc_raise(vm, MRBC_CLASS(TypeError), "wrong type of argument");
    return;
  }

  mrbc_value result = mrbc_string_new_cstr(vm, "Hello, ");
  mrbc_string_append(&result, &name);
  mrbc_string_append_cstr(&result, "!");

  SET_RETURN(result);
}

void
mrbc_hello_world_init(mrbc_vm *vm)
{
  printf("Hello world!\n");

  mrbc_class *class_HelloWorld = mrbc_define_class(vm, "HelloWorld", mrbc_class_object);
  mrbc_define_method(vm, class_HelloWorld, "c_greet", c_hello_world_c_greet);
}
