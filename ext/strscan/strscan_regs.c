#include "strscan.h"

#ifdef HAVE_ONIG_REGION_MEMSIZE
extern size_t onig_region_memsize(const struct re_registers *regs);
#endif

struct match_context {
    VALUE str;
    long curr;
    long offs;
};

#define S_PBEG(s)  (RSTRING_PTR((s)->str))
#define S_LEN(s)  (RSTRING_LEN((s)->str))
#define S_PEND(s)  (S_PBEG(s) + S_LEN(s))
#define CURPTR(s) (S_PBEG(s) + (s)->curr)
#define S_RESTLEN(s) (S_LEN(s) - (s)->curr)

static VALUE StringScannerRegs;

static void
regs_free(void *ptr)
{
    struct re_registers *regs = ptr;
    onig_region_free(regs, 0);
}

static size_t
regs_memsize(const void *ptr)
{
    const struct re_registers *p = ptr;
    size_t size = sizeof(*p);
#ifdef HAVE_ONIG_REGION_MEMSIZE
    size += onig_region_memsize(p);
#endif
    return size;
}

static const rb_data_type_t regs_type = {
    "StringScanner::Regs",
    {0, regs_free, regs_memsize},
    0, 0, RUBY_TYPED_FREE_IMMEDIATELY
};

static struct re_registers *
check_regs(VALUE obj)
{
    return rb_check_typeddata(obj, &regs_type);
}

static VALUE
regs_alloc(VALUE klass)
{
    struct re_registers *regs;

    VALUE obj = TypedData_Make_Struct(klass, struct re_registers, &regs_type, regs);
    onig_region_init(regs);

    return obj;
}

static VALUE
regs_init_copy(VALUE vself, VALUE vorig)
{
    struct re_registers *self, *orig;

    self = check_regs(vself);
    orig = check_regs(vorig);
    if (rb_reg_region_copy(self, orig))
        rb_memerror();

    return vself;
}

static VALUE
regs_clear(VALUE self)
{
    onig_region_clear(check_regs(self));
    return self;
}

static VALUE
regs_region_set(VALUE self, VALUE at, VALUE beg, VALUE end)
{
    onig_region_set(check_regs(self), NUM2INT(at), NUM2INT(beg), NUM2INT(end));
    return self;
}

static VALUE
regs_set_beg(VALUE self, VALUE idx, VALUE val)
{
    check_regs(self)->beg[NUM2INT(idx)] = NUM2LONG(val);

    return self;
}

static VALUE
regs_set_end(VALUE self, VALUE idx, VALUE val)
{
    check_regs(self)->end[NUM2INT(idx)] = NUM2LONG(val);

    return self;
}

static VALUE
regs_get_beg(VALUE self, VALUE idx)
{
    return LONG2NUM(check_regs(self)->beg[NUM2INT(idx)]);
}

static VALUE
regs_get_end(VALUE self, VALUE idx)
{
    return LONG2NUM(check_regs(self)->end[NUM2INT(idx)]);
}

static VALUE
regs_num_regs(VALUE self)
{
    return INT2NUM(check_regs(self)->num_regs);
}

static inline UChar *
match_target(struct match_context *p)
{
    return (UChar *)S_PBEG(p) + p->offs;
}

static OnigPosition
strscan_match(regex_t *reg, VALUE str, struct re_registers *regs, void *args_ptr)
{
    struct match_context *p = (struct match_context *)args_ptr;

    return onig_match(reg,
                      match_target(p),
                      (UChar* )(CURPTR(p) + S_RESTLEN(p)),
                      (UChar* )CURPTR(p),
                      regs,
                      ONIG_OPTION_NONE);
}

static VALUE
regs_onig_match(VALUE self, VALUE pattern, VALUE str, VALUE curr, VALUE offs)
{
    Check_Type(pattern, T_REGEXP);

    struct match_context p = {
        .str = str,
        .curr = NUM2LONG(curr),
        .offs = NUM2LONG(offs)
    };

    OnigPosition ret = rb_reg_onig_match(pattern,
            str,
            strscan_match,
            (void *)&p,
            check_regs(self));

    if (ret == ONIG_MISMATCH) {
        return Qfalse;
    }
    else {
        return LONG2NUM(check_regs(self)->end[0] + NUM2LONG(offs));
    }
}

static OnigPosition
strscan_search(regex_t *reg, VALUE str, struct re_registers *regs, void *args_ptr)
{
    struct match_context *p = (struct match_context *)args_ptr;

    return onig_search(reg,
                       match_target(p),
                       (UChar *)(CURPTR(p) + S_RESTLEN(p)),
                       (UChar *)CURPTR(p),
                       (UChar *)(CURPTR(p) + S_RESTLEN(p)),
                       regs,
                       ONIG_OPTION_NONE);
}

static VALUE
regs_onig_search(VALUE self, VALUE pattern, VALUE str, VALUE curr, VALUE offs)
{
    Check_Type(pattern, T_REGEXP);

    struct match_context p = {
        .str = str,
        .curr = NUM2LONG(curr),
        .offs = NUM2LONG(offs)
    };

    OnigPosition ret = rb_reg_onig_match(pattern,
            str,
            strscan_search,
            (void *)&p,
            check_regs(self));

    if (ret == ONIG_MISMATCH) {
        return Qfalse;
    }
    else {
        return LONG2NUM(check_regs(self)->end[0] + NUM2LONG(offs));
    }
}

static inline void
set_registers(OnigRegion *regs, struct match_context *p, size_t length)
{
    const int at = 0;
    onig_region_clear(regs);
    if (onig_region_set(regs, at, 0, 0)) return;

    regs->beg[at] = p->curr - p->offs;
    regs->end[at] = (p->curr - p->offs) + length;
}

static VALUE
regs_str_match(VALUE self, VALUE pattern, VALUE str, VALUE curr, VALUE offs)
{
    StringValue(str);
    StringValue(pattern);

    rb_enc_check(str, pattern);

    struct match_context mc = {
        .str = str,
        .curr = NUM2LONG(curr),
        .offs = NUM2LONG(offs)
    };
    struct match_context * p = &mc;

    if (S_RESTLEN(p) < RSTRING_LEN(pattern)) {
        return Qfalse;
    }

    if (memcmp(CURPTR(p), RSTRING_PTR(pattern), RSTRING_LEN(pattern)) != 0) {
        return Qfalse;
    }
    set_registers(check_regs(self), p, RSTRING_LEN(pattern));

    return LONG2NUM(check_regs(self)->end[0] + NUM2LONG(offs));
}

static int
named_captures_iter(const OnigUChar *name,
                    const OnigUChar *name_end,
                    int back_num,
                    int *back_refs,
                    OnigRegex regex,
                    void *arg)
{
    VALUE hash = (VALUE)arg;

    VALUE key = rb_str_new((const char *)name, name_end - name);
    VALUE value = RUBY_Qnil;
    int i;
    for (i = 0; i < back_num; i++) {
        value = INT2NUM(back_refs[i]);
    }
    rb_hash_aset(hash, key, value);
    return 0;
}

static VALUE
regs_named_captures(VALUE self, VALUE re)
{
    Check_Type(re, T_REGEXP);

    VALUE hash = rb_hash_new();

    onig_foreach_name(RREGEXP_PTR(re), named_captures_iter, (void *)hash);

    return hash;
}

static VALUE
regs_name_to_backref_number(VALUE self, VALUE re, VALUE str)
{
    Check_Type(re, T_REGEXP);
    Check_Type(str, T_STRING);

    const char *name;
    const char *name_end;
    long i;
    rb_encoding *enc;

    RSTRING_GETMEM(str, name, i);
    name_end = name + i;
    enc = rb_enc_get(str);

    int num;

    num = onig_name_to_backref_number(RREGEXP_PTR(re),
	(const unsigned char* )name, (const unsigned char* )name_end, check_regs(self));
    if (num >= 1) {
	return INT2NUM(num);
    }
    else {
	rb_enc_raise(enc, rb_eIndexError, "undefined group name reference: %.*s",
					  rb_long2int(name_end - name), name);
    }

    UNREACHABLE;
}

void
Init_strscan_regs(void)
{
    VALUE StringScanner = rb_define_class("StringScanner", rb_cObject);
    StringScannerRegs = rb_define_class_under(StringScanner, "Regs", rb_cObject);

    rb_define_alloc_func(StringScannerRegs, regs_alloc);

    rb_define_private_method(StringScannerRegs, "initialize_copy", regs_init_copy, 1);

    rb_define_method(StringScannerRegs, "clear", regs_clear, 0);
    rb_define_method(StringScannerRegs, "region_set", regs_region_set, 3);
    rb_define_method(StringScannerRegs, "set_beg", regs_set_beg, 2);
    rb_define_method(StringScannerRegs, "set_end", regs_set_end, 2);
    rb_define_method(StringScannerRegs, "get_beg", regs_get_beg, 1);
    rb_define_method(StringScannerRegs, "get_end", regs_get_end, 1);
    rb_define_method(StringScannerRegs, "num_regs", regs_num_regs, 0);
    rb_define_method(StringScannerRegs, "onig_match", regs_onig_match, 4);
    rb_define_method(StringScannerRegs, "onig_search", regs_onig_search, 4);
    rb_define_method(StringScannerRegs, "str_match", regs_str_match, 4);
    rb_define_method(StringScannerRegs, "named_captures", regs_named_captures, 1);
    rb_define_method(StringScannerRegs, "name_to_backref_number", regs_name_to_backref_number, 2);
}
