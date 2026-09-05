/* サンプル: Ruby拡張ライブラリの雛形 */
#include <ruby.h>

static VALUE rb_mSample;

static VALUE
sample_add(VALUE self, VALUE a, VALUE b)
{
    int ia = NUM2INT(a);
    int ib = NUM2INT(b);
    return INT2NUM(ia + ib);
}

void
Init_sample(void)
{
    rb_mSample = rb_define_module("Sample");
    rb_define_singleton_method(rb_mSample, "add", sample_add, 2);
}
