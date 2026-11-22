#!/usr/bin/env python3
"""Single source for PC Power's legal texts. Run from the project root:  python3 tools/legal.py
Writes: docs/legal/*.md and *.html (to host), android-app/lib/legal.dart, windows-app/ui/legal.html"""
import html, json, os

VERSION = "2026-11-22.2"          # change this whenever the texts change: both apps ask users to agree again
EFFECTIVE = "22 November 2026"
PUBLISHER = "Mogamat Muneer Miller"
PLACE = "Cape Town, South Africa"
CONTACT = "muneermilleror@gmail.com"

# A paragraph starting with "!" is a term that limits liability or puts risk on the user. It is shown
# in bold so that it stands out, as consumer law expects for such terms.
TERMS = ("Terms of Use", [
 ("1. What this is", [
  f"PC Power is a free app for Windows and Android, published by {PUBLISHER}, {PLACE} (\"we\", \"us\"). It lets you schedule when a computer turns off or on, and control that from your phone.",
  "These terms are the agreement between you and us for using PC Power. By installing or using it you agree to them. If you do not agree, do not use the app.",
  "If you use PC Power for a business, school or other organisation, you confirm that you are allowed to accept these terms for it.",
 ]),
 ("2. What you may do", [
  "You may install and use PC Power, free of charge, on computers and phones that you own or are authorised to manage.",
  "You may not use PC Power to control, turn on, turn off or access a computer without the permission of its owner. Doing so may be a crime, including under South Africa's Cybercrimes Act.",
  "You may not use the app to break any law, to harm anyone, or to interfere with networks or devices that are not yours.",
 ]),
 ("3. Important: what can go wrong", [
  "!PC Power turns computers off and on. Please read this section carefully, because it describes risks that you accept by using the app.",
  "!Unsaved work can be lost. When a computer shuts down, restarts, sleeps or hibernates, whether at once or on a schedule, anything not saved in open programs may be lost, and running tasks such as downloads, backups, updates or recordings may be interrupted. You are responsible for saving work and for choosing safe times.",
  "!It may not always work. Turning a computer on remotely depends on your computer's hardware and settings, your router, your network and your internet provider. A schedule may be missed if the computer is off, the app is not running, or Windows prevents it. Do not rely on PC Power where a failure could cause injury, damage or serious loss.",
  "!Your network setup is your responsibility. If you choose to open ports on your router, switch off \"Only accept phones on my own network\", or use the app over the internet, you do so at your own risk. We describe how to do this as safely as we can, but we cannot see or control your network.",
  "!Changing computer settings is at your own risk. The app and its instructions may suggest changes to Windows, network card and BIOS settings. Changing such settings can affect how your computer behaves.",
 ]),
 ("4. No warranty", [
  "!PC Power is provided free of charge, \"as is\" and \"as available\". To the fullest extent the law allows, we give no warranties or guarantees of any kind, including that the app will be uninterrupted, error-free, secure, or suitable for a particular purpose.",
 ]),
 ("5. Limit of our liability", [
  "!To the fullest extent the law allows, we are not liable for any loss or damage arising from your use of, or inability to use, PC Power. This includes loss of data or unsaved work, loss of profit or business, damage to hardware or software, the cost of electricity, and any indirect or consequential loss.",
  "!If we are found liable despite this section, our total liability to you is limited to R100 (one hundred South African rand).",
  "Nothing in these terms limits or excludes liability that cannot legally be limited or excluded where you live. In particular, nothing here excludes liability for death or personal injury caused by our negligence, for loss caused by our gross negligence, wilful misconduct or fraud, or takes away rights you have under the South African Consumer Protection Act 68 of 2008 or under the consumer protection law of the country you live in. Section 12 says more about specific countries.",
 ]),
 ("6. Your responsibility to us", [
  "!If someone makes a claim against us because you used PC Power unlawfully or in breach of these terms, for example by controlling a computer without permission, you agree to cover the reasonable costs and losses we suffer as a result, to the extent the law allows.",
 ]),
 ("7. Security", [
  "We have designed PC Power to protect the connection between your phone and your computer, but no software is perfectly secure. Keep the pairing code private, pair only your own phones, remove phones you no longer use, and keep the app up to date.",
  f"If you find a security problem in PC Power, please tell us at {CONTACT} so we can fix it.",
  "The signal that turns a computer on (Wake-on-LAN) has no password. That is how the standard works. Anyone already on your network can turn a computer on, although they cannot turn it off or see what is on it through PC Power.",
 ]),
 ("8. Privacy", [
  "Our Privacy Policy explains what information the app uses. In short: PC Power has no accounts, no adverts and no tracking, and we do not receive any information from it.",
 ]),
 ("9. Ownership and other people's software", [
  f"PC Power and its name, design and code belong to {PUBLISHER}. These terms give you permission to use the app; they do not transfer ownership.",
  "PC Power includes open-source software written by other people, used under their licences. You can read those licences in the app under Legal.",
  "\"Windows\" is a trademark of Microsoft, and \"Android\" and \"Google Play\" are trademarks of Google. PC Power is not connected with or endorsed by them.",
 ]),
 ("10. App stores", [
  "If you got PC Power from an app store, the store's own terms also apply. The store is not a party to these terms and is not responsible for the app or for supporting it.",
 ]),
 ("11. Changes and ending", [
  "We may update the app and these terms. If the terms change in an important way, the app will ask you to agree again. We may stop offering or supporting PC Power at any time.",
  "You can stop using PC Power at any time by uninstalling it. Your permission to use it ends if you break these terms.",
 ]),
 ("12. If you live outside South Africa", [
  "PC Power is offered in many countries. Wherever you live, you keep every consumer right that the law of your country says a contract cannot take away. If that law gives you more protection than these terms, the law applies and these terms are read to fit it.",
  "European Economic Area, United Kingdom and Switzerland: if you are a consumer, the mandatory consumer protection law of the country you live in applies to you, and you may bring a claim in the courts of that country. We remain fully liable for damage we cause intentionally or through gross negligence, and for death or personal injury caused by our negligence. The R100 limit in section 5 and the other limits in sections 4 to 6 apply to you only as far as your local law allows.",
  "Australia: nothing in these terms excludes, restricts or modifies the consumer guarantees or any other right you have under the Australian Consumer Law. Where that law lets us limit our liability for failing to meet a consumer guarantee, our liability is limited to supplying the app again.",
  "New Zealand: nothing in these terms limits your rights under the Consumer Guarantees Act 1993 where you use the app as a consumer.",
  "United States and Canada: some states and provinces do not allow certain warranties to be excluded or certain kinds of damages to be limited, so parts of sections 4 and 5 may not apply to you. You may also have rights that vary from place to place. In Quebec, nothing in these terms takes away rights you have under the Consumer Protection Act.",
  "Other countries: the same principle applies. These terms limit our liability only as far as your local law permits.",
  "Age: you must be old enough to enter into a binding agreement where you live, or have the permission of a parent or guardian who accepts these terms for you.",
  "Trade restrictions: you may not use or pass on PC Power where that is prohibited by the export control or sanctions laws that apply to you. The app uses standard encryption.",
  "Language: these terms are written in English. If we provide a translation and it differs from the English version, the English version applies, unless the law where you live says otherwise.",
 ]),
 ("13. Law and disputes", [
  "These terms are governed by the law of South Africa. This choice of law does not take away any protection that the law of the country you live in gives you as a consumer and that cannot be excluded by agreement.",
  "The courts of South Africa may hear disputes about these terms. If you are a consumer, you may instead bring a claim in the courts of the country you live in, and we will not bring a claim against you anywhere else.",
  f"If you have a complaint, please contact us first at {CONTACT} so we can try to resolve it. South African consumers may also approach the National Consumer Commission.",
  "If part of these terms is found to be invalid, the rest still applies.",
 ]),
 ("14. Contact", [
  f"{PUBLISHER}, {PLACE}. Email: {CONTACT}",
 ]),
])

PRIVACY = ("Privacy Policy", [
 ("Summary", [
  "PC Power does not collect, receive or sell any information about you. It has no accounts, no adverts, no analytics and no tracking. Everything it needs stays on your own phone and computer.",
 ]),
 ("1. Who we are", [
  f"PC Power is published by {PUBLISHER}, {PLACE}. For the purposes of South Africa's Protection of Personal Information Act (POPIA), we are the responsible party for the app, although we do not receive any personal information through it. Contact: {CONTACT}",
 ]),
 ("2. Information we collect", [
  "None. PC Power does not send any information to us or to anyone else. We have no server that the app talks to, and we cannot see your devices, your schedules or how you use the app.",
 ]),
 ("3. Information kept on your own devices", [
  "To work, PC Power keeps some technical details on your devices. They never leave your devices except when your phone and your computer talk directly to each other.",
  "On your phone: the names of the computers you paired; their network addresses (IP address, hardware \"MAC\" address and, if you enter one, your public address or DDNS name); a fingerprint of each computer's security certificate; and an access key for each computer, kept in your phone's encrypted storage. These are excluded from Android backups.",
  "On your computer: the computer's name; the pairing code; your schedules; the name and pairing date of each paired phone, with a scrambled (hashed) copy of its access key; the security certificate the app created; and a log file listing recent actions and the network addresses they came from. The log is replaced each time the app starts.",
 ]),
 ("4. How the apps communicate", [
  "Your phone and computer talk directly to each other over your own network, using an encrypted connection. If you set up access from outside your home, they talk directly over the internet in the same encrypted way.",
  "To find computers and to turn them on, the phone sends small signals on your local network. The turn-on signal contains the computer's hardware address and is not encrypted; that is how the Wake-on-LAN standard works.",
  "Your internet provider and network equipment can see that devices are communicating, as with any app, but not what is said over the encrypted connection.",
 ]),
 ("5. Permissions", [
  "The Android app asks only for network access, which it needs to reach your computers. It does not ask for your location, contacts, camera, microphone, files or any other personal data.",
  "The Windows app listens on your network so that paired phones can reach it. With your approval, it can change the Windows power and network-card settings described in the app.",
 ]),
 ("6. Sharing", [
  "We do not share your information with anyone, because we do not have it. PC Power contains no third-party advertising or analytics software.",
 ]),
 ("7. Keeping and deleting information", [
  "The information stays on your devices for as long as you keep the app. To delete it: remove a computer in the phone app, remove a phone in the PC Power window, or uninstall the app. On Windows, uninstalling means: untick \"Start PC Power when I sign in to Windows\", quit the app, then delete the program and the folder named PCPower in your user profile's AppData\\Roaming folder.",
 ]),
 ("8. Security", [
  "The connection between phone and computer is encrypted, each phone has its own access key that you can remove, and pairing a new phone only works on your own network. No system is perfectly secure; see the Terms of Use for the precautions we ask you to take.",
 ]),
 ("9. Children", [
  "PC Power is a general utility and is not aimed at children. It does not knowingly collect information from anyone, including children.",
 ]),
 ("10. Your rights", [
  "Privacy laws such as POPIA in South Africa and the GDPR in Europe give you rights over personal information that organisations hold about you, including to see it, correct it or have it deleted. Because we hold no information about you, there is nothing for us to provide or delete, but you are welcome to contact us with any question.",
  "If you believe your privacy rights have been infringed, South African residents may complain to the Information Regulator (inforegulator.org.za). People elsewhere may contact their local data protection authority.",
 ]),
 ("11. Information for specific regions", [
  "European Economic Area, United Kingdom and Switzerland: under the GDPR and UK GDPR we would be the \"controller\" of any personal data we handled, but we handle none: the app does not send us or anyone else personal data. Nothing is transferred to another country by us, and we carry out no profiling or automated decision-making. You have the rights described in section 10 and may complain to the data protection authority in your country.",
  "United States, including California: we do not collect, sell or share personal information as those terms are used in the California Consumer Privacy Act and similar state laws, and we do not use it for advertising. PC Power is not directed at children under 13 and collects no information from them.",
  "Brazil, Canada, Australia, New Zealand and other countries with privacy laws: the same is true everywhere. We do not collect or receive your personal information, so we do not store it, disclose it or move it across borders.",
 ]),
 ("12. Changes to this policy", [
  "If PC Power changes in a way that affects your privacy, for example if an optional online service is added in future, we will update this policy first and the app will ask you to agree again before that feature is used.",
 ]),
 ("13. Contact", [
  f"{PUBLISHER}, {PLACE}. Email: {CONTACT}",
 ]),
])

DOCS = {"terms": TERMS, "privacy": PRIVACY}

def md(title, sections):
    out = [f"# PC Power: {title}", "", f"Effective {EFFECTIVE}", ""]
    for h, paras in sections:
        out += [f"## {h}", ""]
        for p in paras:
            out += [f"**{p[1:]}**" if p.startswith("!") else p, ""]
    return "\n".join(out)

def body_html(sections):
    out = []
    for h, paras in sections:
        out.append(f"<h3>{html.escape(h)}</h3>")
        for p in paras:
            t = html.escape(p.lstrip("!"))
            out.append(f"<p><b>{t}</b></p>" if p.startswith("!") else f"<p>{t}</p>")
    return "\n".join(out)

def page(title, sections):
    return f"""<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>PC Power: {title}</title>
<style>body{{font:16px/1.6 system-ui,"Segoe UI",sans-serif;max-width:720px;margin:0 auto;padding:24px 18px 60px;color:#1c2330}}
h1{{font-size:26px}}h3{{margin-top:28px}}.d{{color:#667}}@media(prefers-color-scheme:dark){{body{{background:#10141a;color:#e8ecf1}}.d{{color:#8b96a5}}}}</style></head>
<body><h1>PC Power: {title}</h1><p class="d">Effective {EFFECTIVE}</p>
{body_html(sections)}
</body></html>
"""

def dart(sections):
    rows = []
    for h, paras in sections:
        rows.append(f"  ({json.dumps(h)}, <String>[" + ", ".join(json.dumps(p).replace("$", r"\$") for p in paras) + "]),")
    return "\n".join(rows)

os.makedirs("docs/legal", exist_ok=True)
for key, (title, sections) in DOCS.items():
    open(f"docs/legal/{key}.md", "w").write(md(title, sections))
    open(f"docs/legal/{key}.html", "w").write(page(title, sections))

open("android-app/lib/legal.dart", "w").write(f"""// GENERATED by tools/legal.py. Do not edit by hand: change the texts there and run it again.
// A paragraph starting with "!" limits liability or puts risk on the user; it is shown in bold.

const legalVersion = {json.dumps(VERSION)};
const legalEffective = {json.dumps(EFFECTIVE)};

const termsOfUse = <(String, List<String>)>[
{dart(TERMS[1])}
];

const privacyPolicy = <(String, List<String>)>[
{dart(PRIVACY[1])}
];
""")

# ---- open-source notices for the Windows program (the Android app shows its own, built in)
import subprocess
def lic(path):
    for n in ("LICENSE", "LICENSE.txt", "LICENSE.md"):
        f = os.path.join(path, n)
        if os.path.exists(f):
            return open(f, errors="replace").read().strip()
    return "(licence file not found)"
modcache = subprocess.run(["go", "env", "GOMODCACHE"], capture_output=True, text=True, cwd="windows-app").stdout.strip()
goroot = subprocess.run(["go", "env", "GOROOT"], capture_output=True, text=True, cwd="windows-app").stdout.strip()
mods = subprocess.run(["go", "list", "-m", "-f", "{{.Path}} {{.Version}} {{.Dir}}", "all"], capture_output=True, text=True, cwd="windows-app", env={**os.environ, "GOOS": "windows"}).stdout.splitlines()
shipped = {"fyne.io/systray", "golang.org/x/sys"}   # what is actually compiled into PCPower.exe
notices = ["PC Power for Windows includes the following open-source software.", ""]
notices += ["=" * 70, "The Go programming language and standard library", "=" * 70, lic(goroot), ""]
for line in mods:
    parts = line.split(" ")
    if len(parts) == 3 and parts[0] in shipped:
        notices += ["=" * 70, f"{parts[0]} {parts[1]}", "=" * 70, lic(parts[2]), ""]
NOTICES = "\n".join(notices)
open("docs/legal/THIRD-PARTY-NOTICES.txt", "w").write(NOTICES)
open("windows-app/legal_gen.go", "w").write(f"""// GENERATED by tools/legal.py. Do not edit by hand.

package main

// legalVersion changes whenever the Terms of Use or Privacy Policy change; users are then asked to agree again.
const legalVersion = {json.dumps(VERSION)}
""")

open("windows-app/ui/legal.html", "w").write(f"""<!-- GENERATED by tools/legal.py. Do not edit by hand. -->
<div id="legalData" data-version="{VERSION}" hidden></div>
<template id="tplTerms"><p class="hint">Effective {EFFECTIVE}</p>
{body_html(TERMS[1])}
</template>
<template id="tplPrivacy"><p class="hint">Effective {EFFECTIVE}</p>
{body_html(PRIVACY[1])}
</template>
<template id="tplNotices"><pre style="white-space:pre-wrap;font-size:12px">{html.escape(NOTICES)}</pre></template>
""")
print("legal texts written, version", VERSION)
