# Workmanager: the plugin registers a worker via reflection.
-keep class * extends androidx.work.Worker
-keep class * extends androidx.work.CoroutineWorker
-keep class * extends androidx.work.ListenableWorker
-keep class be.tramckrijte.workmanager.** { *; }

# ML Kit text recognition — keep the ENTIRE ML Kit + its GMS vision internals
# so R8 cannot strip the OCR engine (doing so silently broke price reading).
-keep class com.google.mlkit.** { *; }
-keep interface com.google.mlkit.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_** { *; }
-keep class com.google_mlkit_text_recognition.** { *; }
-keep class com.google_mlkit_commons.** { *; }
-dontwarn com.google.mlkit.**
-dontwarn com.google.android.gms.internal.**
# We only ship the Latin recognizer; silence the other script modules.
-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.devanagari.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.korean.**
