# smbj: reflection in the event bus and optional Kerberos/JGSS classes that Android lacks.
-keep class com.hierynomus.** { *; }
-keep class net.engio.mbassy.** { *; }
-dontwarn org.ietf.jgss.**
-dontwarn javax.security.auth.**
-dontwarn javax.el.**
-dontwarn org.slf4j.**
-dontwarn com.hierynomus.**
-dontwarn net.engio.mbassy.**
