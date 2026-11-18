#!/bin/bash
# Build + publish a new Manager version. Every installed copy updates itself on its next start
# (and asks within 2 hours if it is already open). Usage: ./release.sh 4.5.0
set -e; V="$1"; [ -n "$V" ] || { echo "usage: $0 X.Y.Z"; exit 1; }
cd "$(dirname "$0")"
sed -i -E "s/public const string Version = \"[0-9.]+\";/public const string Version = \"$V\";/; s/AssemblyVersion\(\"[0-9.]+\"\)/AssemblyVersion(\"$V.0\")/" Core.cs
A=/usr/lib/mono/4.8-api
mcs -nostdlib -target:winexe -platform:anycpu -optimize+ -codepage:utf8 -out:SharedPC-Manager.exe -win32manifest:app.manifest -win32icon:app.ico \
  -r:$A/mscorlib.dll -r:$A/System.dll -r:$A/System.Core.dll -r:$A/System.Windows.Forms.dll -r:$A/System.Drawing.dll -r:$A/System.Web.Extensions.dll \
  -resource:../manager/common.ps1,common.ps1 -resource:../manager/create-vm.ps1,create-vm.ps1 -resource:../manager/setup-client.ps1,setup-client.ps1 \
  -resource:../manager/client-portal.ps1,client-portal.ps1 Core.cs Router.cs UI.cs Setup.cs
echo "$V" > manager-version.txt      # written last: the exe must be on GitHub before the version says so
echo "built $V - now: git add -A && git commit && git push"
