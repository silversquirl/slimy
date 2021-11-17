// int64 emulation
uvec2 i64(int i) {
	return uvec2(int(i < 0) * -1, i);
}
uvec2 add64(uvec2 a, uvec2 b) {
	uvec2 v;
	v.y = uaddCarry(a.y, b.y, v.x);
	v.x += a.x + b.x;
	return v;
}
uvec2 mul64(uvec2 a, uvec2 b) {
	uvec2 v;
	umulExtended(a.y, b.y, v.x, v.y);
	v.x += a.x*b.y + a.y*b.x;
	return v;
}
// WARNING: DOES NOT WORK WITH SHIFT > 32 (but that's fine because we only need 17)
uvec2 rsh64(uvec2 v, int shift) {
	return uvec2(v.x >> shift, v.x<<(32-shift) | v.y>>shift);
}

uvec2 slime_magic = uvec2(0x5, 0xDEECE66D);
uvec2 slime_mask = uvec2(0xffff, -1);

bool isSlime(ivec2 c) {
	// Calculate slime seed
	uvec2 seed = world_seed;
	seed = add64(seed, i64(c.x*c.x*4987142));
	seed = add64(seed, i64(c.x*5947611));
	seed = add64(seed, mul64(i64(c.y*c.y), uvec2(0, 4392871)));
	seed = add64(seed, i64(c.y*389711));
	seed.y ^= 987234911u;

	// Calculate LCG seed
	seed = (seed ^ slime_magic) & slime_mask;

	// Calculate random value
	int bits, val;
	do {
		seed = add64(mul64(seed, slime_magic), uvec2(0, 0xB)) & slime_mask;
		bits = int(rsh64(seed, 48 - 31).y);
		val = bits % 10;
	} while (bits-val+9 < 0);

	// Check slime chunk
	return val == 0;
}
