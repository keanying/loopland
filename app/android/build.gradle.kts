allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
// 部分 Flutter 插件（如 amap_map）写死了较老的 compileSdk，而新版 androidx
// 依赖要求用 36 编译：统一把 Android 库模块的 compileSdk 提到 36。
subprojects {
    val bumpCompileSdk = {
        extensions.findByType(com.android.build.gradle.LibraryExtension::class.java)?.let {
            if ((it.compileSdk ?: 0) < 36) it.compileSdk = 36
        }
    }
    if (state.executed) bumpCompileSdk() else afterEvaluate { bumpCompileSdk() }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
