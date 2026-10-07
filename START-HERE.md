# Einstieg

Dieses Paket in einen **neuen, leeren Ordner** entpacken. Nicht ueber die alte
Projektversion kopieren und deren Git-Historie nicht fuer das oeffentliche Repo
uebernehmen. Der neue Quelltext und alle Dateinamen sind neutral gehalten.

Zuerst im PowerShell-7.4-Terminal:

```powershell
.\Scripts\Initialize-Local.ps1
.\Tests\Test-Project.ps1
.\Tests\Test-Safety.ps1
```

Danach ausschliesslich `.local/config/lab.psd1` mit echten Werten befuellen.
In `.local/private-terms.txt` eigene private Firmen-, Produkt- und Domainnamen
als zusaetzliche Sperrbegriffe eintragen. Private Installationsskripte, Zertifikate
und Ergebnisse ebenfalls unter `.local` speichern. Secretwerte vorzugsweise in
Key Vault, in der Config nur ihre Namen.

Vor dem ersten Commit in einem neuen Repo:

```powershell
git init
.\Scripts\Enable-GitGuards.ps1
python .\Scripts\check_public.py --require-private-terms
git add .
python .\Scripts\check_public.py --staged --require-private-terms
git diff --cached
```

Noch nichts wurde in Azure angelegt. Erst nach Konfiguration folgen die Stufen
in README.md. NAT/VMs/Gateway brauchen den expliziten Schalter
`-EnableBillableResources`.

Der Ablauf lautet:

1. `Deploy-Lab.ps1`: getrennte Basis-, Netzwerk- und kostenpflichtige Stufen.
2. `Test-Lab.ps1`: automatische Healthchecks plus lokale, gefuehrte Abnahme von
   Login, MFA, Rollen, SQL-Anmeldung der Anwendung und Anwendungsfunktion.
3. `Export-Lab.ps1`: konfigurierte Dateien und Datenbankexporte in privaten Storage;
   `Get-LabExports.ps1` laedt sie lokal herunter und prueft SHA256.
4. `Destroy-Lab.ps1`: Exportnachweise und Eigentumsmarker pruefen, Test-RG loeschen,
   Loeschung kontrollieren. Basis und Exporte bleiben erhalten.

Die normale Dateisicherung hat derzeit ein Limit von 512 MiB pro VM. Fuer einen
fehlgeschlagenen Aufbau ist `-MetadataOnly` moeglich: Das rettet KEINE Gastdaten.
Nach erfolgreichem Dateiexport bleiben Anwendung/SQL-Agent fuer die anschliessende
Loeschung angehalten. Mit `Resume-Lab.ps1` fortsetzen; dann erneut exportieren.

Die Python-/Bash-Pruefungen wurden ausgefuehrt. Neue PowerShell-Pruefungen und ein
Azure-Livetest stehen aus. Ein oeffentliches Repo wurde nicht angelegt oder gepusht.
Die lokale Sperrliste, Hooks und CI ergaenzen deine manuelle Sichtung; sie geben
keine absolute Geheimhaltungs-Garantie. Siehe Docs/PUBLICATION.md.
