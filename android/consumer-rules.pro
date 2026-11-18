# libgojni.so resolves these by JNI name lookup, so R8 must not rename or
# remove them. Mirrors the proguard.txt gomobile ships inside XRay.aar, which
# AGP cannot apply here because the core arrives as a plain jar.
-keep class go.** { *; }
-keep class XRay.** { *; }
