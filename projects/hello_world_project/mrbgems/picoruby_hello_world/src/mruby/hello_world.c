/* picoruby(mruby VM)ビルド向け。
   関数名はmrbgemの命名規則(gem名のハイフンをアンダースコアに置換したもの)に
   合わせる必要がある: gem名 "picoruby-hello_world" -> "picoruby_hello_world"。 */
#include <stdio.h>
#include "mruby.h"
#include "mruby/presym.h"
#include "mruby/string.h"

/* Ruby側のHelloWorld#greetから呼ばれる。挨拶文の組み立て自体をC側でやることで、
   「greetがCのコードを呼ぶ」実装例にしてある。 */
static mrb_value
mrb_hello_world_c_greet(mrb_state *mrb, mrb_value self)
{
  mrb_value name;
  mrb_get_args(mrb, "S", &name);

  mrb_value result = mrb_str_new_cstr(mrb, "Hello, ");
  result = mrb_str_cat_str(mrb, result, name);
  result = mrb_str_cat_cstr(mrb, result, "!");
  return result;
}

void
mrb_picoruby_hello_world_gem_init(mrb_state* mrb)
{
  printf("Hello world!\n");

  struct RClass *class_HelloWorld = mrb_define_class_id(mrb, MRB_SYM(HelloWorld), mrb->object_class);
  mrb_define_method_id(mrb, class_HelloWorld, MRB_SYM(c_greet), mrb_hello_world_c_greet, MRB_ARGS_REQ(1));
}

void
mrb_picoruby_hello_world_gem_final(mrb_state* mrb)
{
}
