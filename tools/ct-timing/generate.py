"""Bind timing fixtures to the real private RSA cores, without algorithm copies."""
import pathlib,sys
ROOT=pathlib.Path(__file__).resolve().parents[2]
def generate(template,source):
    start='// BEGIN RSA SECRET BIGNUM PRIMITIVES';end='// END RSA SECRET BIGNUM PRIMITIVES'
    if source.count(start)!=1 or source.count(end)!=1 or source.index(start)>source.index(end):
        raise ValueError('RSA secret-core markers changed; review the fixture binding')
    return template+'\n'+source.split(start)[1].split(end)[0]
if __name__=='__main__':
    pathlib.Path(sys.argv[1]).write_text(generate((ROOT/'tools/ct-timing/driver.ab').read_text(),(ROOT/'stdlib/abla/crypto/rsa/entry.ab').read_text()))
