# Eigene R8-Regeln für den Release-Build (zusätzlich zu denen von Flutter
# und den Bibliotheken).

# WorkManager (Raum-Widgets) legt seine Room-Datenbank per Reflexion über
# den leeren Konstruktor an. R8 hat ihn sonst entfernt: Absturz schon beim
# Start der App (InitializationProvider, NoSuchMethodException).
-keep class * extends androidx.room.RoomDatabase { <init>(); }
-keep class androidx.work.impl.WorkDatabase_Impl { *; }

# Worker der Widgets: WorkManager erzeugt sie über den Klassennamen.
-keep class * extends androidx.work.ListenableWorker {
    <init>(android.content.Context, androidx.work.WorkerParameters);
}
