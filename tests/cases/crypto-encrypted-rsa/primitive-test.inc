// Test-only public outputs: fixed, non-secret KAT inputs. Not an exported API.
import "abla/crypto"
import "abla/bytes"
trusted fun pbeTestHash(message: string, sha1: bool): string {
    val hash = pbeHash(sha1)
    val budget = PbeBudget(RsaKeyReadLimits())
    val output = nativeByteBuffer(33)
    hash.update(ablaUnsafeStringAddress(message), message.size, budget)
    hash.finish(ablaUnsafePointerAddress(output.address), budget)
    output.adoptString(if (sha1) 20 else 32)
}
trusted fun pbeTestDerive(text: string, salt: string, count: int, sha1: bool, bytes: int): string {
    val password = cryptoPassword(text)
    val budget = PbeBudget(RsaKeyReadLimits())
    val output = nativeByteBuffer(bytes)
    val ok = pbeDerive(password, salt, count, sha1, output, budget)
    val public = byteBuffer()
    if (ok) for (i in 0 until bytes) public.appendText(byteEncode(output.load(i)))
    pbeWipe(ablaUnsafePointerAddress(output.address), bytes)
    public.toText()
}
@inline @export("ct_pbe_sha1")
trusted fun pbeTestSha1(state: int, input: int, scratch: int): void = pbeShaBlock(state, input, scratch, true)
@inline @export("ct_pbe_sha256")
trusted fun pbeTestSha256(state: int, input: int, scratch: int): void = pbeShaBlock(state, input, scratch, false)
@inline @export("ct_pbe_hmac1")
trusted fun pbeTestHmac1(memory: int): void = pbeHmacFixedBody(memory, true)
@inline @export("ct_pbe_hmac256")
trusted fun pbeTestHmac256(memory: int): void = pbeHmacFixedBody(memory, false)
@inline @export("ct_pbe_xor1")
trusted fun pbeTestXor1(memory: int): void = pbeAccumulate(memory, true)
@inline @export("ct_pbe_xor256")
trusted fun pbeTestXor256(memory: int): void = pbeAccumulate(memory, false)
@export("pbe_test_wipe")
trusted fun pbeTestWipe(address: int, size: int): void = pbeWipe(address, size)
// A negative control: genuine password-dependent address selection.
@inline @export("ct_pbe_leak")
trusted fun pbeTestLeak(memory: int): int = ablaUnsafeLoadU8(aesPointer(memory + int(pbeByte(memory).declassify())))

@inline @export("ct_pbe_password_pad")
trusted fun pbeTestPasswordPad(out: int, password: int, size: int): void = pbePadBody(out, password, size, 54)

trusted fun pbeTestMacKey(text: string, salt: string, count: int, sha1: bool): string {
    val password = cryptoPassword(text)
    val output = nativeByteBuffer(if (sha1) 20 else 32)
    val budget = PbeBudget(RsaKeyReadLimits())
    val ok = pbePkcs12MacKey(password, salt, count, sha1, output, budget)
    val public = byteBuffer()
    if (ok) for (i in 0 until output.capacity) public.appendText(byteEncode(output.load(i)))
    pbeWipe(ablaUnsafePointerAddress(output.address), output.capacity)
    public.toText()
}
@inline @export("ct_pbe_mac_compare")
trusted fun pbeTestMacCompare(actual: int, expected: int, size: int): u32 = pbeMacBad(actual, expected, size).declassify()
