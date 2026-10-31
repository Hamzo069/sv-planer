# SV-Planer
Lokale Web-App zur Planung von SV-/Schülerrat-Sitzungen (Tagesordnung, Protokoll, Anwesenheit, Anträge, Jahresplan …).
Alle Daten bleiben im Browser (localStorage), Sicherung per JSON-Export/-Import unter „Daten“. Kein Backend, keine Cloud.

Installierbar als App (PWA): im Browser „Installieren“ / „Zur Startseite hinzufügen“.

## Online-Abstimmung (optional)
Für Umfragen mit Link und QR-Code: einmal `sv-abstimmung.sql` im Supabase-Dashboard unter „SQL Editor“ ausführen. Danach im Reiter „Umfragen“ bei einer Umfrage „Online freischalten“ wählen. Die Seite `abstimmen.html` ist die Abstimmungsseite für Teilnehmende. Ergebnisse sieht nur, wer im Planer angemeldet ist.
