# Keep protocol DTOs' generated serializers resilient to R8 name mangling.
-keepattributes *Annotation*, InnerClasses
-dontnote kotlinx.serialization.**
-keepclassmembers class com.dshanywhere.** {
    *** Companion;
}
-keepclasseswithmembers class com.dshanywhere.** {
    kotlinx.serialization.KSerializer serializer(...);
}
