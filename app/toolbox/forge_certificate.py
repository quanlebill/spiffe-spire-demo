import datetime
import sys
from pathlib import Path

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID

spiffe_id = sys.argv[1]
output_directory = Path(sys.argv[2] if len(sys.argv) > 2 else "/tmp/forged")
output_directory.mkdir(parents=True, exist_ok=True)

private_key = ec.generate_private_key(ec.SECP384R1())
name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "forged")])
now = datetime.datetime.now(datetime.timezone.utc)
certificate = (
    x509.CertificateBuilder()
    .subject_name(name)
    .issuer_name(name)
    .public_key(private_key.public_key())
    .serial_number(x509.random_serial_number())
    .not_valid_before(now)
    .not_valid_after(now + datetime.timedelta(hours=1))
    .add_extension(x509.SubjectAlternativeName([x509.UniformResourceIdentifier(spiffe_id)]), critical=True)
    .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
    .sign(private_key, hashes.SHA384())
)

(output_directory / "forged.pem").write_bytes(certificate.public_bytes(serialization.Encoding.PEM))
(output_directory / "forged.key").write_bytes(
    private_key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    )
)
print(f"forged certificate claiming {spiffe_id} written to {output_directory}")
