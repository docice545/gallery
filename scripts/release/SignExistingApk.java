// HP-only JDK 17 source launcher. No key creation/export or password logging.
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Properties;

class SignExistingApk {
  public static void main(String[] args) {
    try {
      if (args.length != 4) throw new Exception();
      Path android = Path.of(args[0]).toRealPath();
      Properties properties = new Properties();
      try (var input = Files.newInputStream(android.resolve("key.properties"))) {
        properties.load(input); // Identical Java Properties semantics to Gradle.
      }
      Path key = android.resolve(properties.getProperty("storeFile", "")).toRealPath();
      if (!key.equals(android.resolve("key.jks").toRealPath()) ||
          !"foto".equals(properties.getProperty("keyAlias"))) throw new Exception();
      String store = properties.getProperty("storePassword"), password = properties.getProperty("keyPassword");
      if (store == null || password == null || store.contains("\n") || password.contains("\n") ||
          store.contains("\r") || password.contains("\r")) throw new Exception();
      Process process = new ProcessBuilder(args[1], "sign", "--ks", key.toString(),
          "--ks-key-alias", "foto", "--ks-pass", "stdin", "--key-pass", "stdin",
          "--out", args[3], args[2]).redirectOutput(ProcessBuilder.Redirect.DISCARD)
          .redirectError(ProcessBuilder.Redirect.DISCARD).start();
      try (OutputStream input = process.getOutputStream()) {
        input.write((store + "\n" + password + "\n").getBytes(StandardCharsets.UTF_8));
      }
      if (process.waitFor() != 0) throw new Exception();
    } catch (Exception error) {
      System.err.println("FAIL existing-key signing; no credential details printed");
      System.exit(1);
    }
  }
}
