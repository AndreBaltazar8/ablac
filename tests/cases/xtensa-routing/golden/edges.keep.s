.section .text.probe,"ax",@progbits

# literal comment
.literal_position
.literal .Lprobe, 123
	movi	a0, -2049 # edge movi
	addi	a0, a1, -2049 # edge addi
	l32i	a0, a1, -2049 # edge l32i
	s32i	a0, a1, -2049 # edge s32i
	movi	a0, -2048 # edge movi
	addi	a0, a1, -2048 # edge addi
	l32i	a0, a1, -2048 # edge l32i
	s32i	a0, a1, -2048 # edge s32i
	movi	a0, -33 # edge movi
	addi	a0, a1, -33 # edge addi
	l32i	a0, a1, -33 # edge l32i
	s32i	a0, a1, -33 # edge s32i
	movi.n	a0, -32 # edge movi
	addi	a0, a1, -32 # edge addi
	l32i	a0, a1, -32 # edge l32i
	s32i	a0, a1, -32 # edge s32i
	movi.n	a0, -1 # edge movi
	addi.n	a0, a1, -1 # edge addi
	l32i	a0, a1, -1 # edge l32i
	s32i	a0, a1, -1 # edge s32i
	movi.n	a0, 0 # edge movi
	addi	a0, a1, 0 # edge addi
	l32i.n	a0, a1, 0 # edge l32i
	s32i.n	a0, a1, 0 # edge s32i
	movi.n	a0, 1 # edge movi
	addi.n	a0, a1, 1 # edge addi
	l32i	a0, a1, 1 # edge l32i
	s32i	a0, a1, 1 # edge s32i
	movi.n	a0, 15 # edge movi
	addi.n	a0, a1, 15 # edge addi
	l32i	a0, a1, 15 # edge l32i
	s32i	a0, a1, 15 # edge s32i
	movi.n	a0, 16 # edge movi
	addi	a0, a1, 16 # edge addi
	l32i.n	a0, a1, 16 # edge l32i
	s32i.n	a0, a1, 16 # edge s32i
	movi.n	a0, 60 # edge movi
	addi	a0, a1, 60 # edge addi
	l32i.n	a0, a1, 60 # edge l32i
	s32i.n	a0, a1, 60 # edge s32i
	movi.n	a0, 61 # edge movi
	addi	a0, a1, 61 # edge addi
	l32i	a0, a1, 61 # edge l32i
	s32i	a0, a1, 61 # edge s32i
	movi.n	a0, 64 # edge movi
	addi	a0, a1, 64 # edge addi
	l32i	a0, a1, 64 # edge l32i
	s32i	a0, a1, 64 # edge s32i
	movi.n	a0, 95 # edge movi
	addi	a0, a1, 95 # edge addi
	l32i	a0, a1, 95 # edge l32i
	s32i	a0, a1, 95 # edge s32i
	movi	a0, 96 # edge movi
	addi	a0, a1, 96 # edge addi
	l32i	a0, a1, 96 # edge l32i
	s32i	a0, a1, 96 # edge s32i
	movi	a0, 2047 # edge movi
	addi	a0, a1, 2047 # edge addi
	l32i	a0, a1, 2047 # edge l32i
	s32i	a0, a1, 2047 # edge s32i
	movi	a0, 2048 # edge movi
	addi	a0, a1, 2048 # edge addi
	l32i	a0, a1, 2048 # edge l32i
	s32i	a0, a1, 2048 # edge s32i
  mov.n	a0, a0
	add.n	a0, a1, a2
 or a0, a0, a1
	movi	a1, -2049 # edge movi
	addi	a1, a2, -2049 # edge addi
	l32i	a1, a2, -2049 # edge l32i
	s32i	a1, a2, -2049 # edge s32i
	movi	a1, -2048 # edge movi
	addi	a1, a2, -2048 # edge addi
	l32i	a1, a2, -2048 # edge l32i
	s32i	a1, a2, -2048 # edge s32i
	movi	a1, -33 # edge movi
	addi	a1, a2, -33 # edge addi
	l32i	a1, a2, -33 # edge l32i
	s32i	a1, a2, -33 # edge s32i
	movi.n	a1, -32 # edge movi
	addi	a1, a2, -32 # edge addi
	l32i	a1, a2, -32 # edge l32i
	s32i	a1, a2, -32 # edge s32i
	movi.n	a1, -1 # edge movi
	addi.n	a1, a2, -1 # edge addi
	l32i	a1, a2, -1 # edge l32i
	s32i	a1, a2, -1 # edge s32i
	movi.n	a1, 0 # edge movi
	addi	a1, a2, 0 # edge addi
	l32i.n	a1, a2, 0 # edge l32i
	s32i.n	a1, a2, 0 # edge s32i
	movi.n	a1, 1 # edge movi
	addi.n	a1, a2, 1 # edge addi
	l32i	a1, a2, 1 # edge l32i
	s32i	a1, a2, 1 # edge s32i
	movi.n	a1, 15 # edge movi
	addi.n	a1, a2, 15 # edge addi
	l32i	a1, a2, 15 # edge l32i
	s32i	a1, a2, 15 # edge s32i
	movi.n	a1, 16 # edge movi
	addi	a1, a2, 16 # edge addi
	l32i.n	a1, a2, 16 # edge l32i
	s32i.n	a1, a2, 16 # edge s32i
	movi.n	a1, 60 # edge movi
	addi	a1, a2, 60 # edge addi
	l32i.n	a1, a2, 60 # edge l32i
	s32i.n	a1, a2, 60 # edge s32i
	movi.n	a1, 61 # edge movi
	addi	a1, a2, 61 # edge addi
	l32i	a1, a2, 61 # edge l32i
	s32i	a1, a2, 61 # edge s32i
	movi.n	a1, 64 # edge movi
	addi	a1, a2, 64 # edge addi
	l32i	a1, a2, 64 # edge l32i
	s32i	a1, a2, 64 # edge s32i
	movi.n	a1, 95 # edge movi
	addi	a1, a2, 95 # edge addi
	l32i	a1, a2, 95 # edge l32i
	s32i	a1, a2, 95 # edge s32i
	movi	a1, 96 # edge movi
	addi	a1, a2, 96 # edge addi
	l32i	a1, a2, 96 # edge l32i
	s32i	a1, a2, 96 # edge s32i
	movi	a1, 2047 # edge movi
	addi	a1, a2, 2047 # edge addi
	l32i	a1, a2, 2047 # edge l32i
	s32i	a1, a2, 2047 # edge s32i
	movi	a1, 2048 # edge movi
	addi	a1, a2, 2048 # edge addi
	l32i	a1, a2, 2048 # edge l32i
	s32i	a1, a2, 2048 # edge s32i
  mov.n	a1, a0
	add.n	a1, a1, a2
 or a1, a0, a1
	movi	a2, -2049 # edge movi
	addi	a2, a3, -2049 # edge addi
	l32i	a2, a3, -2049 # edge l32i
	s32i	a2, a3, -2049 # edge s32i
	movi	a2, -2048 # edge movi
	addi	a2, a3, -2048 # edge addi
	l32i	a2, a3, -2048 # edge l32i
	s32i	a2, a3, -2048 # edge s32i
	movi	a2, -33 # edge movi
	addi	a2, a3, -33 # edge addi
	l32i	a2, a3, -33 # edge l32i
	s32i	a2, a3, -33 # edge s32i
	movi.n	a2, -32 # edge movi
	addi	a2, a3, -32 # edge addi
	l32i	a2, a3, -32 # edge l32i
	s32i	a2, a3, -32 # edge s32i
	movi.n	a2, -1 # edge movi
	addi.n	a2, a3, -1 # edge addi
	l32i	a2, a3, -1 # edge l32i
	s32i	a2, a3, -1 # edge s32i
	movi.n	a2, 0 # edge movi
	addi	a2, a3, 0 # edge addi
	l32i.n	a2, a3, 0 # edge l32i
	s32i.n	a2, a3, 0 # edge s32i
	movi.n	a2, 1 # edge movi
	addi.n	a2, a3, 1 # edge addi
	l32i	a2, a3, 1 # edge l32i
	s32i	a2, a3, 1 # edge s32i
	movi.n	a2, 15 # edge movi
	addi.n	a2, a3, 15 # edge addi
	l32i	a2, a3, 15 # edge l32i
	s32i	a2, a3, 15 # edge s32i
	movi.n	a2, 16 # edge movi
	addi	a2, a3, 16 # edge addi
	l32i.n	a2, a3, 16 # edge l32i
	s32i.n	a2, a3, 16 # edge s32i
	movi.n	a2, 60 # edge movi
	addi	a2, a3, 60 # edge addi
	l32i.n	a2, a3, 60 # edge l32i
	s32i.n	a2, a3, 60 # edge s32i
	movi.n	a2, 61 # edge movi
	addi	a2, a3, 61 # edge addi
	l32i	a2, a3, 61 # edge l32i
	s32i	a2, a3, 61 # edge s32i
	movi.n	a2, 64 # edge movi
	addi	a2, a3, 64 # edge addi
	l32i	a2, a3, 64 # edge l32i
	s32i	a2, a3, 64 # edge s32i
	movi.n	a2, 95 # edge movi
	addi	a2, a3, 95 # edge addi
	l32i	a2, a3, 95 # edge l32i
	s32i	a2, a3, 95 # edge s32i
	movi	a2, 96 # edge movi
	addi	a2, a3, 96 # edge addi
	l32i	a2, a3, 96 # edge l32i
	s32i	a2, a3, 96 # edge s32i
	movi	a2, 2047 # edge movi
	addi	a2, a3, 2047 # edge addi
	l32i	a2, a3, 2047 # edge l32i
	s32i	a2, a3, 2047 # edge s32i
	movi	a2, 2048 # edge movi
	addi	a2, a3, 2048 # edge addi
	l32i	a2, a3, 2048 # edge l32i
	s32i	a2, a3, 2048 # edge s32i
  mov.n	a2, a0
	add.n	a2, a1, a2
 or a2, a0, a1
	movi	a3, -2049 # edge movi
	addi	a3, a4, -2049 # edge addi
	l32i	a3, a4, -2049 # edge l32i
	s32i	a3, a4, -2049 # edge s32i
	movi	a3, -2048 # edge movi
	addi	a3, a4, -2048 # edge addi
	l32i	a3, a4, -2048 # edge l32i
	s32i	a3, a4, -2048 # edge s32i
	movi	a3, -33 # edge movi
	addi	a3, a4, -33 # edge addi
	l32i	a3, a4, -33 # edge l32i
	s32i	a3, a4, -33 # edge s32i
	movi.n	a3, -32 # edge movi
	addi	a3, a4, -32 # edge addi
	l32i	a3, a4, -32 # edge l32i
	s32i	a3, a4, -32 # edge s32i
	movi.n	a3, -1 # edge movi
	addi.n	a3, a4, -1 # edge addi
	l32i	a3, a4, -1 # edge l32i
	s32i	a3, a4, -1 # edge s32i
	movi.n	a3, 0 # edge movi
	addi	a3, a4, 0 # edge addi
	l32i.n	a3, a4, 0 # edge l32i
	s32i.n	a3, a4, 0 # edge s32i
	movi.n	a3, 1 # edge movi
	addi.n	a3, a4, 1 # edge addi
	l32i	a3, a4, 1 # edge l32i
	s32i	a3, a4, 1 # edge s32i
	movi.n	a3, 15 # edge movi
	addi.n	a3, a4, 15 # edge addi
	l32i	a3, a4, 15 # edge l32i
	s32i	a3, a4, 15 # edge s32i
	movi.n	a3, 16 # edge movi
	addi	a3, a4, 16 # edge addi
	l32i.n	a3, a4, 16 # edge l32i
	s32i.n	a3, a4, 16 # edge s32i
	movi.n	a3, 60 # edge movi
	addi	a3, a4, 60 # edge addi
	l32i.n	a3, a4, 60 # edge l32i
	s32i.n	a3, a4, 60 # edge s32i
	movi.n	a3, 61 # edge movi
	addi	a3, a4, 61 # edge addi
	l32i	a3, a4, 61 # edge l32i
	s32i	a3, a4, 61 # edge s32i
	movi.n	a3, 64 # edge movi
	addi	a3, a4, 64 # edge addi
	l32i	a3, a4, 64 # edge l32i
	s32i	a3, a4, 64 # edge s32i
	movi.n	a3, 95 # edge movi
	addi	a3, a4, 95 # edge addi
	l32i	a3, a4, 95 # edge l32i
	s32i	a3, a4, 95 # edge s32i
	movi	a3, 96 # edge movi
	addi	a3, a4, 96 # edge addi
	l32i	a3, a4, 96 # edge l32i
	s32i	a3, a4, 96 # edge s32i
	movi	a3, 2047 # edge movi
	addi	a3, a4, 2047 # edge addi
	l32i	a3, a4, 2047 # edge l32i
	s32i	a3, a4, 2047 # edge s32i
	movi	a3, 2048 # edge movi
	addi	a3, a4, 2048 # edge addi
	l32i	a3, a4, 2048 # edge l32i
	s32i	a3, a4, 2048 # edge s32i
  mov.n	a3, a0
	add.n	a3, a1, a2
 or a3, a0, a1
	movi	a4, -2049 # edge movi
	addi	a4, a5, -2049 # edge addi
	l32i	a4, a5, -2049 # edge l32i
	s32i	a4, a5, -2049 # edge s32i
	movi	a4, -2048 # edge movi
	addi	a4, a5, -2048 # edge addi
	l32i	a4, a5, -2048 # edge l32i
	s32i	a4, a5, -2048 # edge s32i
	movi	a4, -33 # edge movi
	addi	a4, a5, -33 # edge addi
	l32i	a4, a5, -33 # edge l32i
	s32i	a4, a5, -33 # edge s32i
	movi.n	a4, -32 # edge movi
	addi	a4, a5, -32 # edge addi
	l32i	a4, a5, -32 # edge l32i
	s32i	a4, a5, -32 # edge s32i
	movi.n	a4, -1 # edge movi
	addi.n	a4, a5, -1 # edge addi
	l32i	a4, a5, -1 # edge l32i
	s32i	a4, a5, -1 # edge s32i
	movi.n	a4, 0 # edge movi
	addi	a4, a5, 0 # edge addi
	l32i.n	a4, a5, 0 # edge l32i
	s32i.n	a4, a5, 0 # edge s32i
	movi.n	a4, 1 # edge movi
	addi.n	a4, a5, 1 # edge addi
	l32i	a4, a5, 1 # edge l32i
	s32i	a4, a5, 1 # edge s32i
	movi.n	a4, 15 # edge movi
	addi.n	a4, a5, 15 # edge addi
	l32i	a4, a5, 15 # edge l32i
	s32i	a4, a5, 15 # edge s32i
	movi.n	a4, 16 # edge movi
	addi	a4, a5, 16 # edge addi
	l32i.n	a4, a5, 16 # edge l32i
	s32i.n	a4, a5, 16 # edge s32i
	movi.n	a4, 60 # edge movi
	addi	a4, a5, 60 # edge addi
	l32i.n	a4, a5, 60 # edge l32i
	s32i.n	a4, a5, 60 # edge s32i
	movi.n	a4, 61 # edge movi
	addi	a4, a5, 61 # edge addi
	l32i	a4, a5, 61 # edge l32i
	s32i	a4, a5, 61 # edge s32i
	movi.n	a4, 64 # edge movi
	addi	a4, a5, 64 # edge addi
	l32i	a4, a5, 64 # edge l32i
	s32i	a4, a5, 64 # edge s32i
	movi.n	a4, 95 # edge movi
	addi	a4, a5, 95 # edge addi
	l32i	a4, a5, 95 # edge l32i
	s32i	a4, a5, 95 # edge s32i
	movi	a4, 96 # edge movi
	addi	a4, a5, 96 # edge addi
	l32i	a4, a5, 96 # edge l32i
	s32i	a4, a5, 96 # edge s32i
	movi	a4, 2047 # edge movi
	addi	a4, a5, 2047 # edge addi
	l32i	a4, a5, 2047 # edge l32i
	s32i	a4, a5, 2047 # edge s32i
	movi	a4, 2048 # edge movi
	addi	a4, a5, 2048 # edge addi
	l32i	a4, a5, 2048 # edge l32i
	s32i	a4, a5, 2048 # edge s32i
  mov.n	a4, a0
	add.n	a4, a1, a2
 or a4, a0, a1
	movi	a5, -2049 # edge movi
	addi	a5, a6, -2049 # edge addi
	l32i	a5, a6, -2049 # edge l32i
	s32i	a5, a6, -2049 # edge s32i
	movi	a5, -2048 # edge movi
	addi	a5, a6, -2048 # edge addi
	l32i	a5, a6, -2048 # edge l32i
	s32i	a5, a6, -2048 # edge s32i
	movi	a5, -33 # edge movi
	addi	a5, a6, -33 # edge addi
	l32i	a5, a6, -33 # edge l32i
	s32i	a5, a6, -33 # edge s32i
	movi.n	a5, -32 # edge movi
	addi	a5, a6, -32 # edge addi
	l32i	a5, a6, -32 # edge l32i
	s32i	a5, a6, -32 # edge s32i
	movi.n	a5, -1 # edge movi
	addi.n	a5, a6, -1 # edge addi
	l32i	a5, a6, -1 # edge l32i
	s32i	a5, a6, -1 # edge s32i
	movi.n	a5, 0 # edge movi
	addi	a5, a6, 0 # edge addi
	l32i.n	a5, a6, 0 # edge l32i
	s32i.n	a5, a6, 0 # edge s32i
	movi.n	a5, 1 # edge movi
	addi.n	a5, a6, 1 # edge addi
	l32i	a5, a6, 1 # edge l32i
	s32i	a5, a6, 1 # edge s32i
	movi.n	a5, 15 # edge movi
	addi.n	a5, a6, 15 # edge addi
	l32i	a5, a6, 15 # edge l32i
	s32i	a5, a6, 15 # edge s32i
	movi.n	a5, 16 # edge movi
	addi	a5, a6, 16 # edge addi
	l32i.n	a5, a6, 16 # edge l32i
	s32i.n	a5, a6, 16 # edge s32i
	movi.n	a5, 60 # edge movi
	addi	a5, a6, 60 # edge addi
	l32i.n	a5, a6, 60 # edge l32i
	s32i.n	a5, a6, 60 # edge s32i
	movi.n	a5, 61 # edge movi
	addi	a5, a6, 61 # edge addi
	l32i	a5, a6, 61 # edge l32i
	s32i	a5, a6, 61 # edge s32i
	movi.n	a5, 64 # edge movi
	addi	a5, a6, 64 # edge addi
	l32i	a5, a6, 64 # edge l32i
	s32i	a5, a6, 64 # edge s32i
	movi.n	a5, 95 # edge movi
	addi	a5, a6, 95 # edge addi
	l32i	a5, a6, 95 # edge l32i
	s32i	a5, a6, 95 # edge s32i
	movi	a5, 96 # edge movi
	addi	a5, a6, 96 # edge addi
	l32i	a5, a6, 96 # edge l32i
	s32i	a5, a6, 96 # edge s32i
	movi	a5, 2047 # edge movi
	addi	a5, a6, 2047 # edge addi
	l32i	a5, a6, 2047 # edge l32i
	s32i	a5, a6, 2047 # edge s32i
	movi	a5, 2048 # edge movi
	addi	a5, a6, 2048 # edge addi
	l32i	a5, a6, 2048 # edge l32i
	s32i	a5, a6, 2048 # edge s32i
  mov.n	a5, a0
	add.n	a5, a1, a2
 or a5, a0, a1
	movi	a6, -2049 # edge movi
	addi	a6, a7, -2049 # edge addi
	l32i	a6, a7, -2049 # edge l32i
	s32i	a6, a7, -2049 # edge s32i
	movi	a6, -2048 # edge movi
	addi	a6, a7, -2048 # edge addi
	l32i	a6, a7, -2048 # edge l32i
	s32i	a6, a7, -2048 # edge s32i
	movi	a6, -33 # edge movi
	addi	a6, a7, -33 # edge addi
	l32i	a6, a7, -33 # edge l32i
	s32i	a6, a7, -33 # edge s32i
	movi.n	a6, -32 # edge movi
	addi	a6, a7, -32 # edge addi
	l32i	a6, a7, -32 # edge l32i
	s32i	a6, a7, -32 # edge s32i
	movi.n	a6, -1 # edge movi
	addi.n	a6, a7, -1 # edge addi
	l32i	a6, a7, -1 # edge l32i
	s32i	a6, a7, -1 # edge s32i
	movi.n	a6, 0 # edge movi
	addi	a6, a7, 0 # edge addi
	l32i.n	a6, a7, 0 # edge l32i
	s32i.n	a6, a7, 0 # edge s32i
	movi.n	a6, 1 # edge movi
	addi.n	a6, a7, 1 # edge addi
	l32i	a6, a7, 1 # edge l32i
	s32i	a6, a7, 1 # edge s32i
	movi.n	a6, 15 # edge movi
	addi.n	a6, a7, 15 # edge addi
	l32i	a6, a7, 15 # edge l32i
	s32i	a6, a7, 15 # edge s32i
	movi.n	a6, 16 # edge movi
	addi	a6, a7, 16 # edge addi
	l32i.n	a6, a7, 16 # edge l32i
	s32i.n	a6, a7, 16 # edge s32i
	movi.n	a6, 60 # edge movi
	addi	a6, a7, 60 # edge addi
	l32i.n	a6, a7, 60 # edge l32i
	s32i.n	a6, a7, 60 # edge s32i
	movi.n	a6, 61 # edge movi
	addi	a6, a7, 61 # edge addi
	l32i	a6, a7, 61 # edge l32i
	s32i	a6, a7, 61 # edge s32i
	movi.n	a6, 64 # edge movi
	addi	a6, a7, 64 # edge addi
	l32i	a6, a7, 64 # edge l32i
	s32i	a6, a7, 64 # edge s32i
	movi.n	a6, 95 # edge movi
	addi	a6, a7, 95 # edge addi
	l32i	a6, a7, 95 # edge l32i
	s32i	a6, a7, 95 # edge s32i
	movi	a6, 96 # edge movi
	addi	a6, a7, 96 # edge addi
	l32i	a6, a7, 96 # edge l32i
	s32i	a6, a7, 96 # edge s32i
	movi	a6, 2047 # edge movi
	addi	a6, a7, 2047 # edge addi
	l32i	a6, a7, 2047 # edge l32i
	s32i	a6, a7, 2047 # edge s32i
	movi	a6, 2048 # edge movi
	addi	a6, a7, 2048 # edge addi
	l32i	a6, a7, 2048 # edge l32i
	s32i	a6, a7, 2048 # edge s32i
  mov.n	a6, a0
	add.n	a6, a1, a2
 or a6, a0, a1
	movi	a7, -2049 # edge movi
	addi	a7, a8, -2049 # edge addi
	l32i	a7, a8, -2049 # edge l32i
	s32i	a7, a8, -2049 # edge s32i
	movi	a7, -2048 # edge movi
	addi	a7, a8, -2048 # edge addi
	l32i	a7, a8, -2048 # edge l32i
	s32i	a7, a8, -2048 # edge s32i
	movi	a7, -33 # edge movi
	addi	a7, a8, -33 # edge addi
	l32i	a7, a8, -33 # edge l32i
	s32i	a7, a8, -33 # edge s32i
	movi.n	a7, -32 # edge movi
	addi	a7, a8, -32 # edge addi
	l32i	a7, a8, -32 # edge l32i
	s32i	a7, a8, -32 # edge s32i
	movi.n	a7, -1 # edge movi
	addi.n	a7, a8, -1 # edge addi
	l32i	a7, a8, -1 # edge l32i
	s32i	a7, a8, -1 # edge s32i
	movi.n	a7, 0 # edge movi
	addi	a7, a8, 0 # edge addi
	l32i.n	a7, a8, 0 # edge l32i
	s32i.n	a7, a8, 0 # edge s32i
	movi.n	a7, 1 # edge movi
	addi.n	a7, a8, 1 # edge addi
	l32i	a7, a8, 1 # edge l32i
	s32i	a7, a8, 1 # edge s32i
	movi.n	a7, 15 # edge movi
	addi.n	a7, a8, 15 # edge addi
	l32i	a7, a8, 15 # edge l32i
	s32i	a7, a8, 15 # edge s32i
	movi.n	a7, 16 # edge movi
	addi	a7, a8, 16 # edge addi
	l32i.n	a7, a8, 16 # edge l32i
	s32i.n	a7, a8, 16 # edge s32i
	movi.n	a7, 60 # edge movi
	addi	a7, a8, 60 # edge addi
	l32i.n	a7, a8, 60 # edge l32i
	s32i.n	a7, a8, 60 # edge s32i
	movi.n	a7, 61 # edge movi
	addi	a7, a8, 61 # edge addi
	l32i	a7, a8, 61 # edge l32i
	s32i	a7, a8, 61 # edge s32i
	movi.n	a7, 64 # edge movi
	addi	a7, a8, 64 # edge addi
	l32i	a7, a8, 64 # edge l32i
	s32i	a7, a8, 64 # edge s32i
	movi.n	a7, 95 # edge movi
	addi	a7, a8, 95 # edge addi
	l32i	a7, a8, 95 # edge l32i
	s32i	a7, a8, 95 # edge s32i
	movi	a7, 96 # edge movi
	addi	a7, a8, 96 # edge addi
	l32i	a7, a8, 96 # edge l32i
	s32i	a7, a8, 96 # edge s32i
	movi	a7, 2047 # edge movi
	addi	a7, a8, 2047 # edge addi
	l32i	a7, a8, 2047 # edge l32i
	s32i	a7, a8, 2047 # edge s32i
	movi	a7, 2048 # edge movi
	addi	a7, a8, 2048 # edge addi
	l32i	a7, a8, 2048 # edge l32i
	s32i	a7, a8, 2048 # edge s32i
  mov.n	a7, a0
	add.n	a7, a1, a2
 or a7, a0, a1
	movi	a8, -2049 # edge movi
	addi	a8, a9, -2049 # edge addi
	l32i	a8, a9, -2049 # edge l32i
	s32i	a8, a9, -2049 # edge s32i
	movi	a8, -2048 # edge movi
	addi	a8, a9, -2048 # edge addi
	l32i	a8, a9, -2048 # edge l32i
	s32i	a8, a9, -2048 # edge s32i
	movi	a8, -33 # edge movi
	addi	a8, a9, -33 # edge addi
	l32i	a8, a9, -33 # edge l32i
	s32i	a8, a9, -33 # edge s32i
	movi.n	a8, -32 # edge movi
	addi	a8, a9, -32 # edge addi
	l32i	a8, a9, -32 # edge l32i
	s32i	a8, a9, -32 # edge s32i
	movi.n	a8, -1 # edge movi
	addi.n	a8, a9, -1 # edge addi
	l32i	a8, a9, -1 # edge l32i
	s32i	a8, a9, -1 # edge s32i
	movi.n	a8, 0 # edge movi
	addi	a8, a9, 0 # edge addi
	l32i.n	a8, a9, 0 # edge l32i
	s32i.n	a8, a9, 0 # edge s32i
	movi.n	a8, 1 # edge movi
	addi.n	a8, a9, 1 # edge addi
	l32i	a8, a9, 1 # edge l32i
	s32i	a8, a9, 1 # edge s32i
	movi.n	a8, 15 # edge movi
	addi.n	a8, a9, 15 # edge addi
	l32i	a8, a9, 15 # edge l32i
	s32i	a8, a9, 15 # edge s32i
	movi.n	a8, 16 # edge movi
	addi	a8, a9, 16 # edge addi
	l32i.n	a8, a9, 16 # edge l32i
	s32i.n	a8, a9, 16 # edge s32i
	movi.n	a8, 60 # edge movi
	addi	a8, a9, 60 # edge addi
	l32i.n	a8, a9, 60 # edge l32i
	s32i.n	a8, a9, 60 # edge s32i
	movi.n	a8, 61 # edge movi
	addi	a8, a9, 61 # edge addi
	l32i	a8, a9, 61 # edge l32i
	s32i	a8, a9, 61 # edge s32i
	movi.n	a8, 64 # edge movi
	addi	a8, a9, 64 # edge addi
	l32i	a8, a9, 64 # edge l32i
	s32i	a8, a9, 64 # edge s32i
	movi.n	a8, 95 # edge movi
	addi	a8, a9, 95 # edge addi
	l32i	a8, a9, 95 # edge l32i
	s32i	a8, a9, 95 # edge s32i
	movi	a8, 96 # edge movi
	addi	a8, a9, 96 # edge addi
	l32i	a8, a9, 96 # edge l32i
	s32i	a8, a9, 96 # edge s32i
	movi	a8, 2047 # edge movi
	addi	a8, a9, 2047 # edge addi
	l32i	a8, a9, 2047 # edge l32i
	s32i	a8, a9, 2047 # edge s32i
	movi	a8, 2048 # edge movi
	addi	a8, a9, 2048 # edge addi
	l32i	a8, a9, 2048 # edge l32i
	s32i	a8, a9, 2048 # edge s32i
  mov.n	a8, a0
	add.n	a8, a1, a2
 or a8, a0, a1
	movi	a9, -2049 # edge movi
	addi	a9, a10, -2049 # edge addi
	l32i	a9, a10, -2049 # edge l32i
	s32i	a9, a10, -2049 # edge s32i
	movi	a9, -2048 # edge movi
	addi	a9, a10, -2048 # edge addi
	l32i	a9, a10, -2048 # edge l32i
	s32i	a9, a10, -2048 # edge s32i
	movi	a9, -33 # edge movi
	addi	a9, a10, -33 # edge addi
	l32i	a9, a10, -33 # edge l32i
	s32i	a9, a10, -33 # edge s32i
	movi.n	a9, -32 # edge movi
	addi	a9, a10, -32 # edge addi
	l32i	a9, a10, -32 # edge l32i
	s32i	a9, a10, -32 # edge s32i
	movi.n	a9, -1 # edge movi
	addi.n	a9, a10, -1 # edge addi
	l32i	a9, a10, -1 # edge l32i
	s32i	a9, a10, -1 # edge s32i
	movi.n	a9, 0 # edge movi
	addi	a9, a10, 0 # edge addi
	l32i.n	a9, a10, 0 # edge l32i
	s32i.n	a9, a10, 0 # edge s32i
	movi.n	a9, 1 # edge movi
	addi.n	a9, a10, 1 # edge addi
	l32i	a9, a10, 1 # edge l32i
	s32i	a9, a10, 1 # edge s32i
	movi.n	a9, 15 # edge movi
	addi.n	a9, a10, 15 # edge addi
	l32i	a9, a10, 15 # edge l32i
	s32i	a9, a10, 15 # edge s32i
	movi.n	a9, 16 # edge movi
	addi	a9, a10, 16 # edge addi
	l32i.n	a9, a10, 16 # edge l32i
	s32i.n	a9, a10, 16 # edge s32i
	movi.n	a9, 60 # edge movi
	addi	a9, a10, 60 # edge addi
	l32i.n	a9, a10, 60 # edge l32i
	s32i.n	a9, a10, 60 # edge s32i
	movi.n	a9, 61 # edge movi
	addi	a9, a10, 61 # edge addi
	l32i	a9, a10, 61 # edge l32i
	s32i	a9, a10, 61 # edge s32i
	movi.n	a9, 64 # edge movi
	addi	a9, a10, 64 # edge addi
	l32i	a9, a10, 64 # edge l32i
	s32i	a9, a10, 64 # edge s32i
	movi.n	a9, 95 # edge movi
	addi	a9, a10, 95 # edge addi
	l32i	a9, a10, 95 # edge l32i
	s32i	a9, a10, 95 # edge s32i
	movi	a9, 96 # edge movi
	addi	a9, a10, 96 # edge addi
	l32i	a9, a10, 96 # edge l32i
	s32i	a9, a10, 96 # edge s32i
	movi	a9, 2047 # edge movi
	addi	a9, a10, 2047 # edge addi
	l32i	a9, a10, 2047 # edge l32i
	s32i	a9, a10, 2047 # edge s32i
	movi	a9, 2048 # edge movi
	addi	a9, a10, 2048 # edge addi
	l32i	a9, a10, 2048 # edge l32i
	s32i	a9, a10, 2048 # edge s32i
  mov.n	a9, a0
	add.n	a9, a1, a2
 or a9, a0, a1
	movi	a10, -2049 # edge movi
	addi	a10, a11, -2049 # edge addi
	l32i	a10, a11, -2049 # edge l32i
	s32i	a10, a11, -2049 # edge s32i
	movi	a10, -2048 # edge movi
	addi	a10, a11, -2048 # edge addi
	l32i	a10, a11, -2048 # edge l32i
	s32i	a10, a11, -2048 # edge s32i
	movi	a10, -33 # edge movi
	addi	a10, a11, -33 # edge addi
	l32i	a10, a11, -33 # edge l32i
	s32i	a10, a11, -33 # edge s32i
	movi.n	a10, -32 # edge movi
	addi	a10, a11, -32 # edge addi
	l32i	a10, a11, -32 # edge l32i
	s32i	a10, a11, -32 # edge s32i
	movi.n	a10, -1 # edge movi
	addi.n	a10, a11, -1 # edge addi
	l32i	a10, a11, -1 # edge l32i
	s32i	a10, a11, -1 # edge s32i
	movi.n	a10, 0 # edge movi
	addi	a10, a11, 0 # edge addi
	l32i.n	a10, a11, 0 # edge l32i
	s32i.n	a10, a11, 0 # edge s32i
	movi.n	a10, 1 # edge movi
	addi.n	a10, a11, 1 # edge addi
	l32i	a10, a11, 1 # edge l32i
	s32i	a10, a11, 1 # edge s32i
	movi.n	a10, 15 # edge movi
	addi.n	a10, a11, 15 # edge addi
	l32i	a10, a11, 15 # edge l32i
	s32i	a10, a11, 15 # edge s32i
	movi.n	a10, 16 # edge movi
	addi	a10, a11, 16 # edge addi
	l32i.n	a10, a11, 16 # edge l32i
	s32i.n	a10, a11, 16 # edge s32i
	movi.n	a10, 60 # edge movi
	addi	a10, a11, 60 # edge addi
	l32i.n	a10, a11, 60 # edge l32i
	s32i.n	a10, a11, 60 # edge s32i
	movi.n	a10, 61 # edge movi
	addi	a10, a11, 61 # edge addi
	l32i	a10, a11, 61 # edge l32i
	s32i	a10, a11, 61 # edge s32i
	movi.n	a10, 64 # edge movi
	addi	a10, a11, 64 # edge addi
	l32i	a10, a11, 64 # edge l32i
	s32i	a10, a11, 64 # edge s32i
	movi.n	a10, 95 # edge movi
	addi	a10, a11, 95 # edge addi
	l32i	a10, a11, 95 # edge l32i
	s32i	a10, a11, 95 # edge s32i
	movi	a10, 96 # edge movi
	addi	a10, a11, 96 # edge addi
	l32i	a10, a11, 96 # edge l32i
	s32i	a10, a11, 96 # edge s32i
	movi	a10, 2047 # edge movi
	addi	a10, a11, 2047 # edge addi
	l32i	a10, a11, 2047 # edge l32i
	s32i	a10, a11, 2047 # edge s32i
	movi	a10, 2048 # edge movi
	addi	a10, a11, 2048 # edge addi
	l32i	a10, a11, 2048 # edge l32i
	s32i	a10, a11, 2048 # edge s32i
  mov.n	a10, a0
	add.n	a10, a1, a2
 or a10, a0, a1
	movi	a11, -2049 # edge movi
	addi	a11, a12, -2049 # edge addi
	l32i	a11, a12, -2049 # edge l32i
	s32i	a11, a12, -2049 # edge s32i
	movi	a11, -2048 # edge movi
	addi	a11, a12, -2048 # edge addi
	l32i	a11, a12, -2048 # edge l32i
	s32i	a11, a12, -2048 # edge s32i
	movi	a11, -33 # edge movi
	addi	a11, a12, -33 # edge addi
	l32i	a11, a12, -33 # edge l32i
	s32i	a11, a12, -33 # edge s32i
	movi.n	a11, -32 # edge movi
	addi	a11, a12, -32 # edge addi
	l32i	a11, a12, -32 # edge l32i
	s32i	a11, a12, -32 # edge s32i
	movi.n	a11, -1 # edge movi
	addi.n	a11, a12, -1 # edge addi
	l32i	a11, a12, -1 # edge l32i
	s32i	a11, a12, -1 # edge s32i
	movi.n	a11, 0 # edge movi
	addi	a11, a12, 0 # edge addi
	l32i.n	a11, a12, 0 # edge l32i
	s32i.n	a11, a12, 0 # edge s32i
	movi.n	a11, 1 # edge movi
	addi.n	a11, a12, 1 # edge addi
	l32i	a11, a12, 1 # edge l32i
	s32i	a11, a12, 1 # edge s32i
	movi.n	a11, 15 # edge movi
	addi.n	a11, a12, 15 # edge addi
	l32i	a11, a12, 15 # edge l32i
	s32i	a11, a12, 15 # edge s32i
	movi.n	a11, 16 # edge movi
	addi	a11, a12, 16 # edge addi
	l32i.n	a11, a12, 16 # edge l32i
	s32i.n	a11, a12, 16 # edge s32i
	movi.n	a11, 60 # edge movi
	addi	a11, a12, 60 # edge addi
	l32i.n	a11, a12, 60 # edge l32i
	s32i.n	a11, a12, 60 # edge s32i
	movi.n	a11, 61 # edge movi
	addi	a11, a12, 61 # edge addi
	l32i	a11, a12, 61 # edge l32i
	s32i	a11, a12, 61 # edge s32i
	movi.n	a11, 64 # edge movi
	addi	a11, a12, 64 # edge addi
	l32i	a11, a12, 64 # edge l32i
	s32i	a11, a12, 64 # edge s32i
	movi.n	a11, 95 # edge movi
	addi	a11, a12, 95 # edge addi
	l32i	a11, a12, 95 # edge l32i
	s32i	a11, a12, 95 # edge s32i
	movi	a11, 96 # edge movi
	addi	a11, a12, 96 # edge addi
	l32i	a11, a12, 96 # edge l32i
	s32i	a11, a12, 96 # edge s32i
	movi	a11, 2047 # edge movi
	addi	a11, a12, 2047 # edge addi
	l32i	a11, a12, 2047 # edge l32i
	s32i	a11, a12, 2047 # edge s32i
	movi	a11, 2048 # edge movi
	addi	a11, a12, 2048 # edge addi
	l32i	a11, a12, 2048 # edge l32i
	s32i	a11, a12, 2048 # edge s32i
  mov.n	a11, a0
	add.n	a11, a1, a2
 or a11, a0, a1
	movi	a12, -2049 # edge movi
	addi	a12, a13, -2049 # edge addi
	l32i	a12, a13, -2049 # edge l32i
	s32i	a12, a13, -2049 # edge s32i
	movi	a12, -2048 # edge movi
	addi	a12, a13, -2048 # edge addi
	l32i	a12, a13, -2048 # edge l32i
	s32i	a12, a13, -2048 # edge s32i
	movi	a12, -33 # edge movi
	addi	a12, a13, -33 # edge addi
	l32i	a12, a13, -33 # edge l32i
	s32i	a12, a13, -33 # edge s32i
	movi.n	a12, -32 # edge movi
	addi	a12, a13, -32 # edge addi
	l32i	a12, a13, -32 # edge l32i
	s32i	a12, a13, -32 # edge s32i
	movi.n	a12, -1 # edge movi
	addi.n	a12, a13, -1 # edge addi
	l32i	a12, a13, -1 # edge l32i
	s32i	a12, a13, -1 # edge s32i
	movi.n	a12, 0 # edge movi
	addi	a12, a13, 0 # edge addi
	l32i.n	a12, a13, 0 # edge l32i
	s32i.n	a12, a13, 0 # edge s32i
	movi.n	a12, 1 # edge movi
	addi.n	a12, a13, 1 # edge addi
	l32i	a12, a13, 1 # edge l32i
	s32i	a12, a13, 1 # edge s32i
	movi.n	a12, 15 # edge movi
	addi.n	a12, a13, 15 # edge addi
	l32i	a12, a13, 15 # edge l32i
	s32i	a12, a13, 15 # edge s32i
	movi.n	a12, 16 # edge movi
	addi	a12, a13, 16 # edge addi
	l32i.n	a12, a13, 16 # edge l32i
	s32i.n	a12, a13, 16 # edge s32i
	movi.n	a12, 60 # edge movi
	addi	a12, a13, 60 # edge addi
	l32i.n	a12, a13, 60 # edge l32i
	s32i.n	a12, a13, 60 # edge s32i
	movi.n	a12, 61 # edge movi
	addi	a12, a13, 61 # edge addi
	l32i	a12, a13, 61 # edge l32i
	s32i	a12, a13, 61 # edge s32i
	movi.n	a12, 64 # edge movi
	addi	a12, a13, 64 # edge addi
	l32i	a12, a13, 64 # edge l32i
	s32i	a12, a13, 64 # edge s32i
	movi.n	a12, 95 # edge movi
	addi	a12, a13, 95 # edge addi
	l32i	a12, a13, 95 # edge l32i
	s32i	a12, a13, 95 # edge s32i
	movi	a12, 96 # edge movi
	addi	a12, a13, 96 # edge addi
	l32i	a12, a13, 96 # edge l32i
	s32i	a12, a13, 96 # edge s32i
	movi	a12, 2047 # edge movi
	addi	a12, a13, 2047 # edge addi
	l32i	a12, a13, 2047 # edge l32i
	s32i	a12, a13, 2047 # edge s32i
	movi	a12, 2048 # edge movi
	addi	a12, a13, 2048 # edge addi
	l32i	a12, a13, 2048 # edge l32i
	s32i	a12, a13, 2048 # edge s32i
  mov.n	a12, a0
	add.n	a12, a1, a2
 or a12, a0, a1
	movi	a13, -2049 # edge movi
	addi	a13, a14, -2049 # edge addi
	l32i	a13, a14, -2049 # edge l32i
	s32i	a13, a14, -2049 # edge s32i
	movi	a13, -2048 # edge movi
	addi	a13, a14, -2048 # edge addi
	l32i	a13, a14, -2048 # edge l32i
	s32i	a13, a14, -2048 # edge s32i
	movi	a13, -33 # edge movi
	addi	a13, a14, -33 # edge addi
	l32i	a13, a14, -33 # edge l32i
	s32i	a13, a14, -33 # edge s32i
	movi.n	a13, -32 # edge movi
	addi	a13, a14, -32 # edge addi
	l32i	a13, a14, -32 # edge l32i
	s32i	a13, a14, -32 # edge s32i
	movi.n	a13, -1 # edge movi
	addi.n	a13, a14, -1 # edge addi
	l32i	a13, a14, -1 # edge l32i
	s32i	a13, a14, -1 # edge s32i
	movi.n	a13, 0 # edge movi
	addi	a13, a14, 0 # edge addi
	l32i.n	a13, a14, 0 # edge l32i
	s32i.n	a13, a14, 0 # edge s32i
	movi.n	a13, 1 # edge movi
	addi.n	a13, a14, 1 # edge addi
	l32i	a13, a14, 1 # edge l32i
	s32i	a13, a14, 1 # edge s32i
	movi.n	a13, 15 # edge movi
	addi.n	a13, a14, 15 # edge addi
	l32i	a13, a14, 15 # edge l32i
	s32i	a13, a14, 15 # edge s32i
	movi.n	a13, 16 # edge movi
	addi	a13, a14, 16 # edge addi
	l32i.n	a13, a14, 16 # edge l32i
	s32i.n	a13, a14, 16 # edge s32i
	movi.n	a13, 60 # edge movi
	addi	a13, a14, 60 # edge addi
	l32i.n	a13, a14, 60 # edge l32i
	s32i.n	a13, a14, 60 # edge s32i
	movi.n	a13, 61 # edge movi
	addi	a13, a14, 61 # edge addi
	l32i	a13, a14, 61 # edge l32i
	s32i	a13, a14, 61 # edge s32i
	movi.n	a13, 64 # edge movi
	addi	a13, a14, 64 # edge addi
	l32i	a13, a14, 64 # edge l32i
	s32i	a13, a14, 64 # edge s32i
	movi.n	a13, 95 # edge movi
	addi	a13, a14, 95 # edge addi
	l32i	a13, a14, 95 # edge l32i
	s32i	a13, a14, 95 # edge s32i
	movi	a13, 96 # edge movi
	addi	a13, a14, 96 # edge addi
	l32i	a13, a14, 96 # edge l32i
	s32i	a13, a14, 96 # edge s32i
	movi	a13, 2047 # edge movi
	addi	a13, a14, 2047 # edge addi
	l32i	a13, a14, 2047 # edge l32i
	s32i	a13, a14, 2047 # edge s32i
	movi	a13, 2048 # edge movi
	addi	a13, a14, 2048 # edge addi
	l32i	a13, a14, 2048 # edge l32i
	s32i	a13, a14, 2048 # edge s32i
  mov.n	a13, a0
	add.n	a13, a1, a2
 or a13, a0, a1
	movi	a14, -2049 # edge movi
	addi	a14, a15, -2049 # edge addi
	l32i	a14, a15, -2049 # edge l32i
	s32i	a14, a15, -2049 # edge s32i
	movi	a14, -2048 # edge movi
	addi	a14, a15, -2048 # edge addi
	l32i	a14, a15, -2048 # edge l32i
	s32i	a14, a15, -2048 # edge s32i
	movi	a14, -33 # edge movi
	addi	a14, a15, -33 # edge addi
	l32i	a14, a15, -33 # edge l32i
	s32i	a14, a15, -33 # edge s32i
	movi.n	a14, -32 # edge movi
	addi	a14, a15, -32 # edge addi
	l32i	a14, a15, -32 # edge l32i
	s32i	a14, a15, -32 # edge s32i
	movi.n	a14, -1 # edge movi
	addi.n	a14, a15, -1 # edge addi
	l32i	a14, a15, -1 # edge l32i
	s32i	a14, a15, -1 # edge s32i
	movi.n	a14, 0 # edge movi
	addi	a14, a15, 0 # edge addi
	l32i.n	a14, a15, 0 # edge l32i
	s32i.n	a14, a15, 0 # edge s32i
	movi.n	a14, 1 # edge movi
	addi.n	a14, a15, 1 # edge addi
	l32i	a14, a15, 1 # edge l32i
	s32i	a14, a15, 1 # edge s32i
	movi.n	a14, 15 # edge movi
	addi.n	a14, a15, 15 # edge addi
	l32i	a14, a15, 15 # edge l32i
	s32i	a14, a15, 15 # edge s32i
	movi.n	a14, 16 # edge movi
	addi	a14, a15, 16 # edge addi
	l32i.n	a14, a15, 16 # edge l32i
	s32i.n	a14, a15, 16 # edge s32i
	movi.n	a14, 60 # edge movi
	addi	a14, a15, 60 # edge addi
	l32i.n	a14, a15, 60 # edge l32i
	s32i.n	a14, a15, 60 # edge s32i
	movi.n	a14, 61 # edge movi
	addi	a14, a15, 61 # edge addi
	l32i	a14, a15, 61 # edge l32i
	s32i	a14, a15, 61 # edge s32i
	movi.n	a14, 64 # edge movi
	addi	a14, a15, 64 # edge addi
	l32i	a14, a15, 64 # edge l32i
	s32i	a14, a15, 64 # edge s32i
	movi.n	a14, 95 # edge movi
	addi	a14, a15, 95 # edge addi
	l32i	a14, a15, 95 # edge l32i
	s32i	a14, a15, 95 # edge s32i
	movi	a14, 96 # edge movi
	addi	a14, a15, 96 # edge addi
	l32i	a14, a15, 96 # edge l32i
	s32i	a14, a15, 96 # edge s32i
	movi	a14, 2047 # edge movi
	addi	a14, a15, 2047 # edge addi
	l32i	a14, a15, 2047 # edge l32i
	s32i	a14, a15, 2047 # edge s32i
	movi	a14, 2048 # edge movi
	addi	a14, a15, 2048 # edge addi
	l32i	a14, a15, 2048 # edge l32i
	s32i	a14, a15, 2048 # edge s32i
  mov.n	a14, a0
	add.n	a14, a1, a2
 or a14, a0, a1
	movi	a15, -2049 # edge movi
	addi	a15, a0, -2049 # edge addi
	l32i	a15, a0, -2049 # edge l32i
	s32i	a15, a0, -2049 # edge s32i
	movi	a15, -2048 # edge movi
	addi	a15, a0, -2048 # edge addi
	l32i	a15, a0, -2048 # edge l32i
	s32i	a15, a0, -2048 # edge s32i
	movi	a15, -33 # edge movi
	addi	a15, a0, -33 # edge addi
	l32i	a15, a0, -33 # edge l32i
	s32i	a15, a0, -33 # edge s32i
	movi.n	a15, -32 # edge movi
	addi	a15, a0, -32 # edge addi
	l32i	a15, a0, -32 # edge l32i
	s32i	a15, a0, -32 # edge s32i
	movi.n	a15, -1 # edge movi
	addi.n	a15, a0, -1 # edge addi
	l32i	a15, a0, -1 # edge l32i
	s32i	a15, a0, -1 # edge s32i
	movi.n	a15, 0 # edge movi
	addi	a15, a0, 0 # edge addi
	l32i.n	a15, a0, 0 # edge l32i
	s32i.n	a15, a0, 0 # edge s32i
	movi.n	a15, 1 # edge movi
	addi.n	a15, a0, 1 # edge addi
	l32i	a15, a0, 1 # edge l32i
	s32i	a15, a0, 1 # edge s32i
	movi.n	a15, 15 # edge movi
	addi.n	a15, a0, 15 # edge addi
	l32i	a15, a0, 15 # edge l32i
	s32i	a15, a0, 15 # edge s32i
	movi.n	a15, 16 # edge movi
	addi	a15, a0, 16 # edge addi
	l32i.n	a15, a0, 16 # edge l32i
	s32i.n	a15, a0, 16 # edge s32i
	movi.n	a15, 60 # edge movi
	addi	a15, a0, 60 # edge addi
	l32i.n	a15, a0, 60 # edge l32i
	s32i.n	a15, a0, 60 # edge s32i
	movi.n	a15, 61 # edge movi
	addi	a15, a0, 61 # edge addi
	l32i	a15, a0, 61 # edge l32i
	s32i	a15, a0, 61 # edge s32i
	movi.n	a15, 64 # edge movi
	addi	a15, a0, 64 # edge addi
	l32i	a15, a0, 64 # edge l32i
	s32i	a15, a0, 64 # edge s32i
	movi.n	a15, 95 # edge movi
	addi	a15, a0, 95 # edge addi
	l32i	a15, a0, 95 # edge l32i
	s32i	a15, a0, 95 # edge s32i
	movi	a15, 96 # edge movi
	addi	a15, a0, 96 # edge addi
	l32i	a15, a0, 96 # edge l32i
	s32i	a15, a0, 96 # edge s32i
	movi	a15, 2047 # edge movi
	addi	a15, a0, 2047 # edge addi
	l32i	a15, a0, 2047 # edge l32i
	s32i	a15, a0, 2047 # edge s32i
	movi	a15, 2048 # edge movi
	addi	a15, a0, 2048 # edge addi
	l32i	a15, a0, 2048 # edge l32i
	s32i	a15, a0, 2048 # edge s32i
  mov.n	a15, a0
	add.n	a15, a1, a2
 or a15, a0, a1
movi a16, 1
movi a01, 1
movi a2, +1
movi a2, 0x10
addi a2, a3, +1
add a0, a1, a16
movi a2, symbol
.cfi_startproc
#APP
  movi a2, 1
#NO_APP
.begin no-transform
  or a2, a1, a1
.end no-transform
.ascii "#APP movi a2, 1"
.cfi_endproc
movi.n	a2, 1
