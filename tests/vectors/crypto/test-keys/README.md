These private keys are public test fixtures. Never use them outside tests.
The 768- and 1024-bit keys exercise legacy-size handling; the RSA-PSS key
exercises algorithm-specific refusal. The generator deliberately refuses
weak sizes and does not produce RSA-PSS keys.

The five TLS keys are distinct, fixed test identities. Tests create fresh
certificates from them; these keys are not secrets and must never be trusted
for any real service.
