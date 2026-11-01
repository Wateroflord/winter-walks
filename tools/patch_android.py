"""Настраивает Android-проект: разрешения и название."""
import pathlib, re
ROOT = pathlib.Path("android/app")
m = ROOT / "src/main/AndroidManifest.xml"
t = m.read_text(encoding="utf-8")
for p in ["android.permission.INTERNET", "android.permission.ACCESS_FINE_LOCATION", "android.permission.ACCESS_COARSE_LOCATION"]:
    if p not in t:
        t = re.sub(r"(<manifest[^>]*>)", rf'\1\n    <uses-permission android:name="{p}"/>', t, count=1)
t = re.sub(r'android:label="[^"]*"', 'android:label="Winter Walks"', t, count=1)

inner = "        <intent>\n            <action android:name=\"android.intent.action.VIEW\"/>\n            <data android:scheme=\"https\"/>\n        </intent>\n        <intent>\n            <action android:name=\"android.intent.action.VIEW\"/>\n            <data android:scheme=\"geo\"/>\n        </intent>\n"
if "android:scheme=\"geo\"" not in t:
    if "<queries>" in t:
        t = t.replace("<queries>", "<queries>\n" + inner.rstrip("\n"), 1)
    else:
        t = t.replace("</manifest>", "    <queries>\n" + inner + "    </queries>\n</manifest>")

m.write_text(t, encoding="utf-8")
# Новые версии file_picker требуют свежий compileSdk.
g = ROOT / "build.gradle.kts"
gs = g.read_text(encoding="utf-8")
gs = re.sub(r"compileSdk = [^\n]+", "compileSdk = 36", gs, count=1)
g.write_text(gs, encoding="utf-8")
# Плагины, собранные под старый compileSdk (file_picker), поднимаем до 36.
root = pathlib.Path("android/build.gradle.kts")
rs = root.read_text(encoding="utf-8")
if "compileSdkVersion" not in rs:
    rs = """subprojects {
    afterEvaluate {
        val ext = extensions.findByName("android")
        if (ext != null) {
            try {
                ext.javaClass.getMethod("compileSdkVersion", Int::class.javaPrimitiveType).invoke(ext, 36)
            } catch (e: Exception) {
            }
        }
    }
}

""" + rs
    root.write_text(rs, encoding="utf-8")
print("patched")
