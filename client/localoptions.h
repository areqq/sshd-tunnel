/* localoptions.h - static client-only build for Broadcom STB (Brahma B15, armv7l)
 * VU+ Uno 4K SE / Enigma2, kernel 4.1.x
 * Cel: tylko klient, wylacznie nowoczesna kryptografia. */

/* ---------- wylaczamy calkowicie strone serwerowa ---------- */
#define DROPBEAR_SVR_PASSWORD_AUTH 0   /* awaryjny serwer: wylacznie klucz */
#define DROPBEAR_SVR_PUBKEY_AUTH   1   /* serwer: logowanie kluczem */
#define DROPBEAR_SVR_PAM_AUTH      0
#define DROPBEAR_SVR_MULTIUSER     1   /* musi zostac: dbclient tez sprawdza ten flag przy starcie */
#define DROPBEAR_SVR_LOCALTCPFWD   0
#define DROPBEAR_SVR_REMOTETCPFWD  0
#define DROPBEAR_SVR_AGENTFWD      0
#define DROPBEAR_SVR_LOCALSTREAMFWD  0
#define DROPBEAR_SVR_REMOTESTREAMFWD 0
#define DROPBEAR_SFTPSERVER        0
#define DROPBEAR_DELAY_HOSTKEY     0   /* host-key wbudowany, nic nie zapisujemy */
#define DROPBEAR_X11FWD            0

/* ---------- wymiana kluczy: post-quantum + curve25519 ---------- */
#define DROPBEAR_MLKEM768          1   /* mlkem768x25519-sha256  (RFC-owy PQ, OpenSSH >=10) */
#define DROPBEAR_SNTRUP761         1   /* sntrup761x25519-sha512 (OpenSSH >=8.5) */
#define DROPBEAR_CURVE25519        1   /* curve25519-sha256 */
#define DROPBEAR_ECDH              1   /* ecdh-sha2-nistp256/384/521 */
#define DROPBEAR_DH_GROUP14_SHA256 1   /* fallback dla starszych serwerow */
#define DROPBEAR_DH_GROUP16        0
#define DROPBEAR_DH_GROUP14_SHA1   0
#define DROPBEAR_DH_GROUP1         0

/* ---------- szyfry: tylko AEAD + CTR ---------- */
#define DROPBEAR_CHACHA20POLY1305  1   /* chacha20-poly1305@openssh.com */
#define DROPBEAR_ENABLE_GCM_MODE   1   /* aes256-gcm@openssh.com, aes128-gcm@openssh.com */
#define DROPBEAR_ENABLE_CTR_MODE   1   /* aes256-ctr, aes128-ctr */
#define DROPBEAR_ENABLE_CBC_MODE   0
#define DROPBEAR_AES256            1
#define DROPBEAR_AES128            1
#define DROPBEAR_3DES              0

/* ---------- MAC: zero SHA1 ---------- */
#define DROPBEAR_SHA2_256_HMAC     1
#define DROPBEAR_SHA2_512_HMAC     1
#define DROPBEAR_SHA1_HMAC         0
#define DROPBEAR_SHA1_96_HMAC      0

/* ---------- klucze / podpisy ---------- */
#define DROPBEAR_ED25519           1   /* ssh-ed25519 */
#define DROPBEAR_ECDSA             1   /* ecdsa-sha2-nistp* */
#define DROPBEAR_RSA               1   /* rsa-sha2-256 */
#define DROPBEAR_RSA_SHA1          0   /* stare ssh-rsa wylaczone */
#define DROPBEAR_DSS               0
#define DROPBEAR_SK_KEYS           1   /* klucze FIDO/U2F (sk-ed25519, sk-ecdsa) */
#define DROPBEAR_DEFAULT_RSA_SIZE  3072

/* ---------- funkcje klienta ---------- */
#define DROPBEAR_CLI_PASSWORD_AUTH 1
#define DROPBEAR_CLI_PUBKEY_AUTH   1
#define DROPBEAR_CLI_AGENTFWD      1
#define DROPBEAR_CLI_LOCALTCPFWD   1
#define DROPBEAR_CLI_REMOTETCPFWD  1
#define DROPBEAR_CLI_PROXYCMD      1
#define DROPBEAR_CLI_NETCAT        1   /* -B / tryb nc, przydatne do ProxyJump */
#define DROPBEAR_USER_ALGO_LIST    1   /* -c / -m / -o KexAlgorithms z linii polecen */
#define DROPBEAR_USE_SSH_CONFIG    1   /* czyta ~/.ssh/config */
#define DROPBEAR_USE_PASSWORD_ENV  1
#define DROPBEAR_CLI_COMPRESSION   0

/* ---------- rozne ---------- */
#define DROPBEAR_SMALL_CODE        0   /* szybsza krypto, kosztem ~kilkudziesieciu kB */
#define DROPBEAR_REEXEC            0   /* niepotrzebne bez serwera, ulatwia statyk */

/* wbudowany klucz klienta (keys/box_id) - patrz embedded_creds.h */
#define DROPBEAR_USE_EMBEDDED_CREDS 1
