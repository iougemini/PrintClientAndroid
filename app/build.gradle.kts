plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.yuhua.printclient"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.yuhua.printclient"
        minSdk = 23
        targetSdk = 35
        versionCode = 1
        versionName = "1.0.0"

        // 首次启动预填的内网地址。
        // 想换默认值：命令行 -PserverUrl=http://192.168.1.50:8090 或直接改这一行。
        val defaultServer = (project.findProperty("serverUrl") as String?) ?: "http://192.168.1.50:8090"
        buildConfigField("String", "DEFAULT_SERVER_URL", "\"$defaultServer\"")
    }

    buildFeatures {
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    buildTypes {
        debug {
            isMinifyEnabled = false
            versionNameSuffix = "-debug"
        }
        release {
            // 内网自用，不做混淆，避免 WebView 桥接被 R8 改名
            isMinifyEnabled = false
            isShrinkResources = false
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }

    packaging {
        resources.excludes += setOf("META-INF/*.kotlin_module")
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("com.google.android.material:material:1.12.0")
}
