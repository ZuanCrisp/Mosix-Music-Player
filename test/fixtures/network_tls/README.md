This self-signed certificate and private key are public test fixtures, never
production credentials. They let the HTTPS test exercise certificate rejection
and explicit certificate trust without relying on an external server.

Generated with:
```
openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 3650 -subj '/CN=network-fixture.invalid'
```
