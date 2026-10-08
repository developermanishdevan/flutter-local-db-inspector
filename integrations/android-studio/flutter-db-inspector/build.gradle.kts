import org.jetbrains.intellij.platform.gradle.TestFrameworkType
import org.jetbrains.kotlin.gradle.dsl.JvmDefaultMode
import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import org.jetbrains.kotlin.gradle.dsl.KotlinVersion
import org.gradle.process.ExecOperations
import java.io.ByteArrayOutputStream
import javax.inject.Inject

plugins {
    id("org.jetbrains.kotlin.jvm") version "2.3.21"
    id("org.jetbrains.intellij.platform") version "2.19.0"
}

group = providers.gradleProperty("pluginGroup").get()
version = providers.gradleProperty("pluginVersion").get()

kotlin {
    jvmToolchain(21)
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_21)
        // 2025.1 (251) bundles the Kotlin 2.1 standard library: don't call newer stdlib APIs.
        apiVersion.set(KotlinVersion.KOTLIN_2_1)
        languageVersion.set(KotlinVersion.KOTLIN_2_2)
        // Call platform interface default methods directly (no DefaultImpls bridges).
        jvmDefault.set(JvmDefaultMode.NO_COMPATIBILITY)
    }
}

repositories {
    mavenCentral()
    intellijPlatform {
        defaultRepositories()
    }
}

/** A local IDE installation to build against (see gradle.properties). */
val localPlatform: File? = providers.gradleProperty("platformLocalPath").orNull
    ?.takeIf { it.isNotBlank() }
    ?.let(::file)
    ?.takeIf { it.exists() }

dependencies {
    intellijPlatform {
        if (localPlatform != null) {
            local(localPlatform.path)
        } else {
            intellijIdeaCommunity(providers.gradleProperty("platformVersion"))
        }
        testFramework(TestFrameworkType.Platform)
    }
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.opentest4j:opentest4j:1.3.0")
}

// Shared web UI ------------------------------------------------------------------

/**
 * Builds the shared web UI (`shared/web-ui`, see its README) with npm and
 * copies `dist/` to `<outputDir>/web-ui/`, which becomes a resource root: the
 * plugin serves the files under `web-ui/` from its jar to a JCEF browser.
 */
abstract class BuildWebUi @Inject constructor(private val exec: ExecOperations) : DefaultTask() {
    /** `shared/web-ui`. */
    @get:Internal
    abstract val webUiDir: DirectoryProperty

    /** Everything that ends up in the bundle (the UI imports protocol code from the VS Code extension). */
    @get:InputFiles
    @get:PathSensitive(PathSensitivity.RELATIVE)
    abstract val sources: ConfigurableFileCollection

    @get:OutputDirectory
    abstract val outputDir: DirectoryProperty

    @TaskAction
    fun build() {
        val dir = webUiDir.get().asFile
        val windows = System.getProperty("os.name").lowercase().contains("windows")
        val npm = if (windows) "npm.cmd" else "npm"
        val nodeFound = try {
            exec.exec {
                commandLine(if (windows) "node.exe" else "node", "--version")
                standardOutput = ByteArrayOutputStream()
                isIgnoreExitValue = true
            }.exitValue == 0
        } catch (_: Exception) {
            false
        }
        if (!nodeFound) {
            throw GradleException(
                "Node.js was not found on PATH. It is needed to build the shared web UI ($dir). " +
                    "Install Node.js 20+ or build without the web UI with -PskipWebUi (the plugin then uses its Swing UI).",
            )
        }
        if (!dir.resolve("node_modules").isDirectory) {
            exec.exec { workingDir = dir; commandLine(npm, "ci") }
        }
        exec.exec { workingDir = dir; commandLine(npm, "run", "build:production") }

        val target = outputDir.get().asFile.resolve("web-ui")
        target.deleteRecursively()
        val dist = dir.resolve("dist")
        dist.walkTopDown()
            // A development build may have left a source map behind.
            .filter { it.isFile && it.extension != "map" }
            .forEach { it.copyTo(target.resolve(it.relativeTo(dist).path), overwrite = true) }
        if (!target.resolve("index.html").isFile) throw GradleException("The web UI build did not produce $dist/index.html")
    }
}

val repoRoot: File = rootProject.projectDir.resolve("../../..").canonicalFile
// `-PskipWebUi` (or `-PskipWebUi=true`): build without node; the plugin then always uses its Swing UI.
val skipWebUi = providers.gradleProperty("skipWebUi").map { it != "false" }.getOrElse(false)

val buildWebUi = tasks.register<BuildWebUi>("buildWebUi") {
    group = "build"
    description = "Builds shared/web-ui and stages it as the plugin's web-ui/ resources (skip with -PskipWebUi)."
    val webUi = repoRoot.resolve("shared/web-ui")
    webUiDir.set(webUi)
    sources.from(
        fileTree(webUi.resolve("src")),
        webUi.resolve("build.mjs"),
        webUi.resolve("package.json"),
        webUi.resolve("package-lock.json"),
        webUi.resolve("tsconfig.json"),
        fileTree(repoRoot.resolve("integrations/vscode/flutter-db-inspector/src")),
    )
    outputDir.set(layout.buildDirectory.dir("generated/webUi"))
}

// The generated web-ui/ directory becomes a resource root (and the task runs before processResources).
if (!skipWebUi) {
    sourceSets.main { resources.srcDir(buildWebUi.flatMap { it.outputDir }) }
}

intellijPlatform {
    // Both start a headless IDE or need extra tooling; this plugin has no
    // settings to index and no GUI forms to instrument.
    buildSearchableOptions = false
    instrumentCode = false

    pluginConfiguration {
        id = "com.manishdevan.flutterdb"
        name = "Flutter DB Inspector"
        version = project.version.toString()
        changeNotes = """
            <b>1.0.0</b>
            <ul>
              <li>New web UI (JCEF), the same as in VS Code and DevTools: database tree, tabs, data grid, value inspector, schema, SQL console with history and saved queries, statistics.</li>
              <li><b>Query</b> button on SQL tables opens the SQL console with a starter <code>SELECT</code>; nothing runs until you press Run.</li>
              <li>Wording follows the storage engine (rows / objects / entries).</li>
              <li>The classic Swing UI stays available: Settings | Tools | Flutter DB Inspector | Use the web UI, and it is used automatically where JCEF is not supported.</li>
              <li>Requires <code>flutter_db_inspector</code> 1.0.0 in the app.</li>
            </ul>
        """.trimIndent()
        ideaVersion {
            sinceBuild = providers.gradleProperty("pluginSinceBuild")
            untilBuild = provider { null }
        }
    }

    pluginVerification {
        ides {
            val locals = listOf("/Applications/Android Studio.app", "/Applications/IntelliJ IDEA CE.app")
                .map(::file)
                .filter { it.exists() }
            if (locals.isEmpty()) recommended() else locals.forEach { local(it) }
        }
    }
}

tasks {
    test {
        // The integration test spawns the Dart demo server from the repository root.
        systemProperty("fdi.repoRoot", repoRoot.path)
        testLogging {
            events("passed", "skipped", "failed")
            exceptionFormat = org.gradle.api.tasks.testing.logging.TestExceptionFormat.FULL
            showStandardStreams = false
        }
    }
}
