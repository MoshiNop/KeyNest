val ndkProp = (if (rootProject.hasProperty("com.moshinop.keynest.ndkVersion")) {
    rootProject.property("com.moshinop.keynest.ndkVersion").toString()
} else {
    System.getProperty("com.moshinop.keynest.ndkVersion") ?: "28.2.13676358"
})
System.setProperty("com.moshinop.keynest.ndkVersion", ndkProp)
println("ndkVersion: $ndkProp")

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.layout.buildDirectory.set(File("../build"))
subprojects {
    project.layout.buildDirectory.set(rootProject.layout.buildDirectory.get().dir(project.name))
}
subprojects {
    project.evaluationDependsOn(":app")
    if (project.path == ":file_picker_writable" || project.path == ":flutter_email_sender") {
        apply(plugin = "com.android.library")
        apply(plugin = "kotlin-android")
        project.configure<org.jetbrains.kotlin.gradle.dsl.KotlinAndroidProjectExtension> {
            jvmToolchain(17)
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory.get())
}
