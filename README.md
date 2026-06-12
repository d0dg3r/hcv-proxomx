# HashiCorp Vault HA Cluster auf Proxmox VE (Rocky Linux 10 LXCs)

Dieses Repository enthält die Terraform-Konfigurationen und Shell-Skripte zur Bereitstellung, Initialisierung und Absicherung eines hochverfügbaren (HA) 3-Node HashiCorp Vault Clusters auf Proxmox VE. 

Die Container basieren auf Rocky Linux 10 LXCs. Die interne Kommunikation sowie Client-Verbindungen sind durch eine dedizierte `.lan` PKI abgesichert.

---

## Inhaltsverzeichnis

- [Architektur & Infrastruktur](#architektur-infrastruktur)
- [Repository-Struktur und Dateien](#repository-struktur-und-dateien)
- [Step-by-Step Setup-Anleitung](#step-by-step-setup-anleitung)
- [Vertrauensstellung auf Clients einrichten](#vertrauensstellung-auf-clients-einrichten)
- [Reverse Proxy Konfiguration](#reverse-proxy-konfiguration)
- [Speicherorte der Secrets in Vault](#speicherorte-der-secrets-in-vault)
- [SSH Key Signing (Client-Zertifikate)](#ssh-key-signing-client-zertifikate)
  - [Server-Konfiguration](#server-konfiguration)
    - [Option A: Automatische Einrichtung](#option-a-automatische-einrichtung-uber-das-skript-empfohlen)
    - [Option B: Manuelle Einrichtung](#option-b-manuelle-einrichtung)
    - [Option C: Zugriff einschränken über Authorized Principals (Optional)](#option-c-zugriff-einschranken-uber-authorized-principals-optional)
  - [SSH-Rollen und Benutzerberechtigungen (Policies)](#ssh-rollen-und-benutzerberechtigungen-policies)
  - [Client-Nutzung (Wie man sich anmeldet)](#client-nutzung-wie-man-sich-anmeldet)
- [ssh-sec: Automatisierter SSH-Zertifikats-Wrapper](#ssh-sec-automatisierter-ssh-zertifikats-wrapper)

---

## Architektur & Infrastruktur

- **Plattform:** 3x unprivilegierte Rocky Linux 10 LXC-Container auf Proxmox VE.
- **Speicher-Backend:** Raft (Integrated Storage) mit automatischem Peering über `retry_join`.
- **Hohe Verfügbarkeit (HA):** Ein aktiver Leader mit zwei Standby-Repliken.
- **Sicherheit (TLS):** 
  - Initiales Bootstrap mit Terraform-generierten selbstsignierten Zertifikaten.
  - Endgültige Absicherung über eine interne Vault-PKI mit einer **20 Jahre** gültigen Root-CA und **10 Jahre** gültigen Node-Zertifikaten.
  - Generiertes Zertifikats-Bundle (PEM) für einen externen Reverse-Proxy.

---

## Repository-Struktur und Dateien

- **Terraform-Konfigurationen:**
  - [main.tf](file:///home/joe/Development/hcv-proxomx/main.tf): Lädt das Rocky Linux 10 Template herunter und provisioniert die 3 LXC-Container (`vault-01`, `vault-02`, `vault-03`).
  - [tls.tf](file:///home/joe/Development/hcv-proxomx/tls.tf): Erstellt die initiale Bootstrap-CA und signiert die temporären TLS-Zertifikate für das Cluster-Bootstrapping.
  - [provision.tf](file:///home/joe/Development/hcv-proxomx/provision.tf): Kopiert TLS-Zertifikate, Konfigurationen und führt das Installationsskript auf den Nodes aus.
  - [variables.tf](file:///home/joe/Development/hcv-proxomx/variables.tf) / [providers.tf](file:///home/joe/Development/hcv-proxomx/providers.tf) / [outputs.tf](file:///home/joe/Development/hcv-proxomx/outputs.tf): Konfigurationsvariablen, Provider-Definitionen und Terraform-Outputs.
- **Templates und Installations-Skripte:**
  - [templates/vault.hcl.tftpl](file:///home/joe/Development/hcv-proxomx/templates/vault.hcl.tftpl): Jinja/Terraform-Template für die Vault-Konfigurationsdatei (`/etc/vault.d/vault.hcl`).
  - [scripts/install-vault.sh](file:///home/joe/Development/hcv-proxomx/scripts/install-vault.sh): Installiert das offizielle HashiCorp Vault-Repository und -Paket auf Rocky Linux 10.
- **Betriebs- und Setup-Skripte (Lokal auszuführen):**
  - [scripts/init-and-unseal.sh](file:///home/joe/Development/hcv-proxomx/scripts/init-and-unseal.sh): Initialisiert das Vault-Cluster und entsiegelt (unseals) alle 3 Nodes automatisch.
  - [scripts/create-admin-user.sh](file:///home/joe/Development/hcv-proxomx/scripts/create-admin-user.sh): Aktiviert das `userpass`-Backend und legt einen Admin-Benutzer mit Vollrechten an.
  - [scripts/setup-pki.sh](file:///home/joe/Development/hcv-proxomx/scripts/setup-pki.sh): Konfiguriert die interne Root-CA für die Domain `.lan` in Vault (20 Jahre Gültigkeit).
  - [scripts/replace-vault-certs.sh](file:///home/joe/Development/hcv-proxomx/scripts/replace-vault-certs.sh): Erstellt neue 10-Jahres-Zertifikate für die Nodes sowie den Reverse Proxy, verteilt diese und führt einen Rolling Restart der Nodes durch.
  - [scripts/setup-ssh-signing.sh](file:///home/joe/Development/hcv-proxomx/scripts/setup-ssh-signing.sh): Konfiguriert das SSH-Client-Key-Signing in Vault.
  - [scripts/install-ssh-ca.sh](file:///home/joe/Development/hcv-proxomx/scripts/install-ssh-ca.sh): Installiert den CA-Key auf einem beliebigen Server.
  - [scripts/ssh-sec](file:///home/joe/Development/hcv-proxomx/scripts/ssh-sec): Ein Wrapper für nahtloses SSH-Key-Signing und Login.

---

## Step-by-Step Setup-Anleitung

### 1. Infrastruktur bereitstellen (Terraform)
Stelle sicher, dass deine `terraform.tfvars` die korrekten Proxmox API-Tokens und Netzwerkeinstellungen enthält. Führe anschließend Folgendes aus:

```bash
terraform init
terraform apply -auto-approve
```
Dies lädt das Rocky Linux 10 Template herunter, erstellt die LXCs, installiert Vault und konfiguriert das anfängliche TLS-Bootstrap.

### 2. Initialisierung & Entsiegelung (Unseal)
Führe das unseal-Skript aus, um das Cluster zu initialisieren und die Nodes zu entsiegeln:

```bash
./scripts/init-and-unseal.sh
```
> [!IMPORTANT]
> Dieses Skript generiert die Datei `secrets/vault-keys.json`, welche den Root-Token sowie die Unseal-Keys enthält. Diese Datei befindet sich im `secrets/`-Ordner, ist in `.gitignore` eingetragen und sollte streng vertraulich behandelt werden.

### 3. Administrator-Konto erstellen
Um nicht dauerhaft den Root-Token verwenden zu müssen, erstellen wir einen Admin-Benutzer:

```bash
./scripts/create-admin-user.sh
```
Das Skript gibt den Benutzernamen (`admin`) und ein zufällig generiertes Passwort aus. Du kannst dich damit unter `https://10.1.3.221:8200` im UI einloggen.

### 4. PKI für `.lan` einrichten
Um Zertifikate für die lokale Infrastruktur auszustellen, richten wir eine PKI secrets engine ein:

```bash
./scripts/setup-pki.sh
```
Dadurch wird die `secrets/lan_root_ca.crt` mit 20 Jahren Gültigkeit erstellt und eine Rolle `lan` für 10 Jahre gültige Zertifikate definiert.

### 5. Zertifikate austauschen (Rolling Replacement)
Ersetze die temporären Bootstrap-Zertifikate der Nodes durch die neuen 10-Jahres-Zertifikate der Vault-PKI:

```bash
./scripts/replace-vault-certs.sh
```
Dieses Skript:
1. Erstellt neue Zertifikate für alle Nodes und den Reverse Proxy.
2. Lädt die Zertifikate auf die LXC-Nodes hoch.
3. Startet die Vault-Dienste nacheinander neu und entsiegelt die Nodes wieder automatisch.
4. Erstellt die Datei [lan_root_ca.crt](file:///home/joe/Development/hcv-proxomx/secrets/lan_root_ca.crt) lokal im `secrets/`-Verzeichnis.

---

## Vertrauensstellung auf Clients einrichten

Damit deine lokalen Clients (z. B. dein Browser oder das CLI) den Zertifikaten von Vault und dem Reverse Proxy vertrauen, muss das Root-CA-Zertifikat ([lan_root_ca.crt](file:///home/joe/Development/hcv-proxomx/secrets/lan_root_ca.crt)) auf den jeweiligen Systemen importiert werden.

### Linux

#### Arch Linux (Host)
```bash
sudo cp secrets/lan_root_ca.crt /etc/ca-certificates/trust-source/anchors/vault_lan_root_ca.crt
sudo trust extract-compat
```

#### Debian / Ubuntu
```bash
sudo cp secrets/lan_root_ca.crt /usr/local/share/ca-certificates/vault_lan_root_ca.crt
sudo update-ca-certificates
```

#### RHEL / Rocky Linux / Fedora
```bash
sudo cp secrets/lan_root_ca.crt /etc/pki/ca-trust/source/anchors/vault_lan_root_ca.crt
sudo update-ca-trust
```

---

### Windows

#### Per GUI (Grafische Oberfläche)
1. Drücke `Win + R`, gib `certmgr.msc` ein (für den aktuellen Benutzer) oder `certlm.msc` (für den gesamten Computer) und drücke Enter.
2. Navigiere zu **Vertrauenswürdige Stammzertifizierungsstellen** -> **Zertifikate**.
3. Mache einen Rechtsklick auf den Ordner **Zertifikate** und wähle **Alle Aufgaben** -> **Importieren...**.
4. Wähle die Datei `secrets/lan_root_ca.crt` aus (stelle sicher, dass der Dateifilter im Explorer auf "Alle Dateien" steht).
5. Schließe den Assistenten ab. Die CA wird nun als vertrauenswürdig eingestuft.

#### Per PowerShell (Administrator)
```powershell
Import-Certificate -FilePath .\secrets\lan_root_ca.crt -CertStoreLocation Cert:\LocalMachine\Root
```

---

### macOS

#### Per GUI (Schlüsselbundverwaltung)
1. Öffne die App **Schlüsselbundverwaltung** (Keychain Access).
2. Wähle links den Schlüsselbund **System** (oder "Anmeldung", falls du es nur für deinen Benutzer brauchst).
3. Ziehe die Datei `secrets/lan_root_ca.crt` per Drag-and-Drop in die Liste der Zertifikate.
4. Mache einen Doppelklick auf das importierte Zertifikat (`lan Internal Root CA`).
5. Klappe den Bereich **Vertrauen** (Trust) auf und setze die Option **Bei Verwendung dieses Zertifikats** auf **Immer vertrauen** (Always Trust).
6. Schließe das Fenster und autorisiere die Änderung mit deinem Passwort.

#### Per Terminal (CLI)
```bash
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain secrets/lan_root_ca.crt
```

---

### iOS (iPhone / iPad)

1. Sende die Datei `secrets/lan_root_ca.crt` per AirDrop auf dein iOS-Gerät, sende sie dir per E-Mail oder lade sie in deine iCloud Drive / **Dateien**-App.
2. Tippe auf die Datei. Es erscheint der Hinweis, dass das Profil geladen wurde.
3. Öffne die App **Einstellungen** -> ganz oben siehst du den Punkt **Profil geladen**. Tippe darauf und wähle oben rechts **Installieren**.
4. Navigiere in den **Einstellungen** zu: **Allgemein** -> **Info** -> **Zertifikatsvertrauenseinstellungen** (ganz unten).
5. Aktiviere unter "Volles Vertrauen für Root-Zertifikate aktivieren" den Schalter für **lan Internal Root CA**.

---

### Android

*Hinweis: Je nach Android-Hersteller (Samsung, Google, Xiaomi, etc.) und OS-Version können die Menübezeichnungen variieren.*

1. Übertrage die Datei `secrets/lan_root_ca.crt` auf den internen Speicher deines Android-Geräts (z.B. per USB, E-Mail oder Nextcloud).
2. Öffne die **Einstellungen** deines Geräts.
3. Navigiere zu **Sicherheit** -> **Erweiterte Einstellungen** -> **Verschlüsselung und Anmeldedaten** -> **Ein Zertifikat installieren** (oder suche in den Einstellungen direkt nach `CA-Zertifikat`).
4. Wähle **CA-Zertifikat**.
5. Bestätige die Sicherheitswarnung.
6. Wähle die Datei `secrets/lan_root_ca.crt` aus dem Dateimanager aus und bestätige die Installation mit deiner PIN/Muster/Fingerabdruck.

---

## Reverse Proxy Konfiguration

Für den externen Zugriff via `https://vault.lan` (z. B. über Nginx, HAProxy oder Apache) wurden folgende Zertifikate generiert:

- **Zertifikat:** [reverse_proxy_vault.lan.crt](file:///home/joe/Development/hcv-proxomx/secrets/reverse_proxy_vault.lan.crt)
- **Privater Schlüssel:** [reverse_proxy_vault.lan.key](file:///home/joe/Development/hcv-proxomx/secrets/reverse_proxy_vault.lan.key)
- **Kombiniertes Bundle:** [reverse_proxy_vault.lan.pem](file:///home/joe/Development/hcv-proxomx/secrets/reverse_proxy_vault.lan.pem) (enthält Zertifikat, privaten Schlüssel und Root-CA)

Verwende das kombinierte PEM-Bundle oder das Zertifikat+Key-Paar in deiner Reverse-Proxy-Konfiguration und leite den Traffic an die IP-Adressen der Vault-Nodes auf Port `8200` weiter.

---

## Speicherorte der Secrets in Vault

Alle wichtigen Schlüssel, Zertifikate und Konfigurationen werden nach dem Ausführen der jeweiligen Skripte automatisch verschlüsselt in der KV-Engine (Key-Value v2) des Vaults gesichert.

Folgende Pfade werden in Vault verwendet:

| Inhalt / Zweck | Pfad in Vault | Enthaltene Felder / Keys |
| :--- | :--- | :--- |
| **Initialisierungsschlüssel** (Unseal-Keys & Root-Token) | `hc-vault/vault-keys` | `unseal_keys_b64`, `root_token` uvm. |
| **Admin-Benutzer** (Lokales CLI/UI-Konto) | `hc-vault/admin-user` | `username`, `password` |
| **Lokales Root-CA-Zertifikat** (`lan_root_ca.crt`) | `hc-vault/root-ca` | `certificate` |
| **SSH-CA-Public-Key** (`vault_ssh_ca.pub`) | `hc-vault/ssh-ca` | `public_key` |
| **Reverse-Proxy-Zertifikate** (Cert, Key & PEM-Bundle) | `hc-vault/reverse-proxy-certs` | `certificate`, `private_key`, `combined_pem` |

Um ein Secret manuell über das CLI abzufragen, verwende:
```bash
vault kv get <Pfad>
```
Beispiel:
```bash
vault kv get hc-vault/admin-user
```

---

## SSH Key Signing (Client-Zertifikate)

Mit dem SSH-Zertifikats-Signierungs-Verfahren von Vault müssen keine SSH-Public-Keys mehr manuell in den `authorized_keys` der Zielserver hinterlegt werden. Stattdessen vertrauen die Server einer von Vault verwalteten SSH-Zertifizierungsstelle (CA). Benutzer lassen ihre temporären Schlüssel von Vault signieren.

Zur Einrichtung wurde das Skript [setup-ssh-signing.sh](file:///home/joe/Development/hcv-proxomx/scripts/setup-ssh-signing.sh) erstellt und ausgeführt. Es hat die CA in Vault konfiguriert und den öffentlichen CA-Schlüssel als [vault_ssh_ca.pub](file:///home/joe/Development/hcv-proxomx/secrets/vault_ssh_ca.pub) gespeichert.

### Server-Konfiguration

Um die Konfiguration auf den Zielservern (z. B. Rocky Linux, Debian, Ubuntu, Arch Linux) zu vereinfachen, wurde das Skript [install-ssh-ca.sh](file:///home/joe/Development/hcv-proxomx/scripts/install-ssh-ca.sh) erstellt.

#### Option A: Automatische Einrichtung über das Skript (Empfohlen)

Kopiere das Skript [install-ssh-ca.sh](file:///home/joe/Development/hcv-proxomx/scripts/install-ssh-ca.sh) auf deinen Zielserver und führe es mit Root-Rechten aus:

```bash
chmod +x install-ssh-ca.sh
sudo ./install-ssh-ca.sh
```

Das Skript:
1. Erstellt `/etc/ssh/trusted-user-ca-keys.pem` mit dem eingebetteten CA-Schlüssel.
2. Setzt die korrekten Dateiberechtigungen.
3. Konfiguriert die `TrustedUserCAKeys` Direktive in der `/etc/ssh/sshd_config` (ohne doppelte Einträge).
4. Erkennt und startet den passenden SSH-Dienst (`sshd` auf Arch/RedHat, `ssh` auf Debian/Ubuntu) neu.

#### Option B: Manuelle Einrichtung

Falls du die Konfiguration lieber manuell durchführen möchtest:

1. **CA-Schlüssel auf den Server kopieren:**
   Kopiere die Datei [vault_ssh_ca.pub](file:///home/joe/Development/hcv-proxomx/secrets/vault_ssh_ca.pub) auf den Zielserver unter `/etc/ssh/trusted-user-ca-keys.pem`.
   
   ```bash
   # Setze die korrekten Berechtigungen:
   chown root:root /etc/ssh/trusted-user-ca-keys.pem
   chmod 644 /etc/ssh/trusted-user-ca-keys.pem
   ```

2. **sshd-Konfiguration anpassen:**
   Füge die folgende Zeile am Ende der `/etc/ssh/sshd_config` hinzu:
   
   ```text
   TrustedUserCAKeys /etc/ssh/trusted-user-ca-keys.pem
   ```

3. **SSH-Dienst neu starten:**
   * Auf RedHat/Arch/Rocky Linux:
     ```bash
     systemctl restart sshd
     ```
   * Auf Debian/Ubuntu:
     ```bash
     systemctl restart ssh
     ```

Nun vertraut der SSH-Dienst dieses Servers jedem SSH-Schlüssel, der von der Vault-CA signiert wurde.

#### Option C: Zugriff einschränken über Authorized Principals (Optional)

Standardmäßig erlaubt der SSH-Dienst nach der Einrichtung jedem Benutzer, der ein von der Vault-CA signiertes Zertifikat besitzt, den Login (sofern der Benutzername im Zertifikat enthalten ist). Wenn du einschränken möchtest, welche Zertifikate auf welchen Servern erlaubt sind, kannst du **Authorized Principals** nutzen.

1. **sshd-Konfiguration anpassen:**
   Füge folgende Zeile in die `/etc/ssh/sshd_config` auf dem Zielserver hinzu:
   
   ```text
   AuthorizedPrincipalsFile /etc/ssh/authorized_principals/%u
   ```

2. **Erlaubte Principals definieren:**
   Erstelle auf dem Zielserver die Datei `/etc/ssh/authorized_principals/root` (für den Login als `root`) und trage dort ein oder mehrere Merkmale (Principals) ein, die im Zertifikat stehen müssen (jeweils eines pro Zeile):
   
   ```text
   vault-admin-access
   pve-global-admin
   ```

3. **SSH-Dienst neu starten:**
   * Auf RedHat/Arch/Rocky Linux:
     ```bash
     systemctl restart sshd
     ```
   * Auf Debian/Ubuntu:
     ```bash
     systemctl restart ssh
     ```

Wenn sich nun jemand als `root` anmeldet, prüft der SSH-Dienst, ob das Zertifikat von der CA signiert wurde **und** ob das Zertifikat das Principal `vault-admin-access` oder `pve-global-admin` enthält. Falls nicht, wird der Login blockiert, selbst wenn das Zertifikat von derselben CA ausgestellt wurde.

---

### SSH-Rollen und Benutzerberechtigungen (Policies)

Vault regelt den SSH-Zugriff über Rollen (die definieren, welche Optionen erlaubt sind) und Policies (die festlegen, welcher Vault-Benutzer auf welche Rolle zugreifen darf).

#### 1. SSH-Rolle in Vault erstellen
Eine Rolle definiert die maximal erlaubte Gültigkeitsdauer (`max_ttl`), die erlaubten Unix-Benutzernamen (`allowed_users`) und die aktivierten SSH-Erweiterungen (z. B. Terminal-Zugriff oder Port-Weiterleitungen).

Beispiel zum Erstellen einer restriktiven Admin-Rolle für `root` (inklusive Agent-Forwarding):
```bash
vault write ssh-client-signer/roles/admin-role - <<EOF
{
  "key_type": "ca",
  "allow_user_certificates": true,
  "allowed_users": "root,admin",
  "default_extensions": {
    "permit-pty": "",
    "permit-port-forwarding": "",
    "permit-agent-forwarding": ""
  },
  "max_ttl": "30m",
  "ttl": "10m"
}
EOF
```

#### 2. Berechtigungs-Richtlinien (Policies) definieren
Erstelle lokale HCL-Dateien, um die Rechte für die Rollen einzuschränken.

* **Richtliniendatei für Entwickler (`dev-ssh.hcl`):**
  ```hcl
  # Erlaubt nur das Signieren über die client-role
  path "ssh-client-signer/sign/client-role" {
    capabilities = ["create", "update"]
  }
  ```

* **Richtliniendatei für Administratoren (`admin-ssh.hcl`):**
  ```hcl
  # Erlaubt das Signieren über die admin-role und client-role
  path "ssh-client-signer/sign/admin-role" {
    capabilities = ["create", "update"]
  }
  path "ssh-client-signer/sign/client-role" {
    capabilities = ["create", "update"]
  }
  ```

Registriere die Richtlinien in Vault (als Admin/Root):
```bash
vault policy write dev-ssh-policy dev-ssh.hcl
vault policy write admin-ssh-policy admin-ssh.hcl
```

#### 3. Richtlinie (Policy) einem Benutzer zuordnen

##### Über die Befehlszeile (CLI)
Ordne die erstellte Policy dem gewünschten Benutzer im `userpass`-Backend zu:

```bash
# Weist dem Benutzer "chefentwickler" die dev-ssh-policy zu
vault write auth/userpass/users/chefentwickler policies="dev-ssh-policy"

# Weist dem Benutzer "joe" die admin-ssh-policy zu
vault write auth/userpass/users/joe policies="admin-ssh-policy"
```

##### Über die Weboberfläche (Web UI)
1. **Einloggen**: Rufe `https://vault.lan` auf und melde dich als `admin` an.
2. **Policy anlegen**: 
   - Gehe im oberen Menü auf **Policies** -> **Create ACL policy**.
   - Gib der Policy einen Namen (z. B. `admin-ssh-policy`) und füge den HCL-Inhalt aus Schritt 2 ein.
   - Klicke auf **Create policy**.
3. **Policy zuweisen**:
   - Gehe im oberen Menü auf **Access** -> **Auth Methods** -> **userpass**.
   - Klicke bei dem gewünschten Benutzer auf die drei Punkte (`...`) ganz rechts und wähle **Edit user**.
   - Trage im Feld **Generated Token's Policies** den Namen der Policy ein (z. B. `admin-ssh-policy`).
   - Klicke auf **Save**.

---

### Client-Nutzung (Wie man sich anmeldet)

Jeder Benutzer (z. B. ein Administrator) kann nun einen kurzlebigen SSH-Schlüssel signieren lassen, um sich anzumelden:

1. **SSH-Schlüsselpaar erzeugen (falls noch nicht vorhanden):**
   ```bash
   ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519
   ```

2. **Bei Vault anmelden und Schlüssel signieren lassen:**
   Die Zertifikate werden mit einer Gültigkeit von 10 Minuten ausgestellt (max. 30 Minuten). Aufgrund der Sicherheitsrichtlinien musst du den Parameter `valid_principals` angeben, um festzulegen, als welcher Unix-Benutzer du dich anmelden möchtest:
   
   ```bash
   export VAULT_CACERT="/pfad/zu/secrets/lan_root_ca.crt"
   export VAULT_ADDR="https://vault.lan"
   
   # 1. Login
   vault login -method=userpass username=admin
   
   # 2. Signieren für normale Benutzer (über client-role)
   vault write -field=signed_key ssh-client-signer/sign/client-role \
       public_key=@~/.ssh/id_ed25519.pub \
       valid_principals="testuser" > ~/.ssh/id_ed25519-cert.pub
       
   # ODER: Signieren für administrative Logins (über admin-role, inkl. Agent-Forwarding)
   vault write -field=signed_key ssh-client-signer/sign/admin-role \
       public_key=@~/.ssh/id_ed25519.pub \
       valid_principals="root" > ~/.ssh/id_ed25519-cert.pub
   ```

3. **Zertifikat prüfen:**
   Du kannst die Details und Gültigkeit des generierten Zertifikats inspizieren:
   ```bash
   ssh-keygen -Lf ~/.ssh/id_ed25519-cert.pub
   ```

4. **Verbindung herstellen:**
   Beim Verbindungsaufbau sendet der SSH-Client das Zertifikat automatisch mit, sofern es im gleichen Ordner wie der private Schlüssel liegt:
   
   ```bash
   ssh -i ~/.ssh/id_ed25519 root@dein-zielserver.lan
   ```

---

## ssh-sec: Automatisierter SSH-Zertifikats-Wrapper

Um den manuellen Ablauf (Anmelden bei Vault, Schlüssel signieren lassen, SSH mit Zertifikat ausführen) vollständig zu automatisieren, wurden Wrapper-Skripte für Linux/macOS sowie für Windows bereitgestellt.

### Linux / macOS (`ssh-sec`)

#### Installation

Kopiere das Skript in ein Verzeichnis deines lokalen `$PATH` (z. B. `/usr/local/bin/`), damit du es systemweit nutzen kannst:

```bash
sudo cp scripts/ssh-sec /usr/local/bin/ssh-sec
sudo chmod +x /usr/local/bin/ssh-sec
```

#### Nutzung

Du kannst `ssh-sec` genau wie den normalen `ssh`-Befehl verwenden. Es reicht alle zusätzlichen Parameter direkt an SSH weiter:

```bash
ssh-sec [user@]hostname [ssh_options]
```

---

### Windows (`ssh-sec.ps1`)

Für Windows-Clients, die den nativen OpenSSH-Client (in Windows 10/11 integriert) in der PowerShell nutzen möchten, gibt es das PowerShell-Gegenstück [ssh-sec.ps1](file:///home/joe/Development/hcv-proxomx/scripts/ssh-sec.ps1).

#### Installation

1. Stelle sicher, dass das `vault` CLI installiert und im Windows-`PATH` registriert ist.
2. Kopiere das PowerShell-Skript an einen Ort deiner Wahl (oder füge das Verzeichnis [scripts](file:///home/joe/Development/hcv-proxomx/scripts) zu deinem Benutzer-`PATH` hinzu).

#### Nutzung

Führe das Skript in einer PowerShell-Konsole aus:

```powershell
.\scripts\ssh-sec.ps1 [user@]hostname [ssh_options]
```

Beispiel:
```powershell
.\scripts\ssh-sec.ps1 root@10.1.3.221
```

---

### Funktionsweise im Hintergrund (beide Skripte):
1. **Ziel-Parsing:** Es ermittelt den Benutzernamen (z. B. `root`) und die IP/Hostname des Zielservers. Wird kein Benutzername angegeben, wird dein lokaler Benutzername verwendet.
2. **Vault-Statusprüfung:** Es prüft, ob eine aktive Vault-Sitzung vorliegt. Falls nicht, fordert es dich interaktiv per `vault login` zur Authentifizierung auf.
3. **Schlüsselerkennung:** Es sucht nach deinem lokalen SSH-Schlüssel (bevorzugt `id_ed25519.pub`, sonst `id_rsa.pub` im SSH-Verzeichnis).
4. **Zertifikatssignierung:** Es lässt deinen öffentlichen Schlüssel bei Vault für den gewünschten Ziel-Benutzer (Principal) signieren und speichert das Zertifikat als `*-cert.pub` ab.
5. **Verbindung:** Führt den originalen `ssh`-Befehl mit dem privaten Schlüssel und dem frisch signierten Zertifikat aus.


