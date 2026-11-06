SECTIONS {
 . = 0x40000000;
 .text : { *(.literal .literal.*) *(.iram1*.literal) *(.iram1 .iram1.*) *(.text .text.*) }
 . = ALIGN(4);
 .rodata : { *(.rodata .rodata.*) }
 .data : { *(.data .data.*) *(.esp_system_init_fn.*) }
 .bss : { *(.bss .bss.*) *(COMMON) }
}
/* Comparison-only SDK bindings. This image is not executed or a board image. */
PROVIDE(__udivdi3 = 0x40020000);
PROVIDE(_data_start = 0x40020010);
PROVIDE(_frxt_dispatch = 0x40020020);
PROVIDE(_heap_start = 0x40020030);
PROVIDE(_iram_end = 0x40020040);
PROVIDE(_iram_start = 0x40020050);
PROVIDE(_rtc_fast_reserved_end = 0x40020060);
PROVIDE(_rtc_fast_reserved_start = 0x40020070);
PROVIDE(_rtc_slow_reserved_end = 0x40020080);
PROVIDE(_rtc_slow_reserved_start = 0x40020090);
PROVIDE(_xt_coproc_savecs = 0x400200a0);
PROVIDE(memset = 0x400200b0);
PROVIDE(xthal_window_spill_nw = 0x400200c0);
