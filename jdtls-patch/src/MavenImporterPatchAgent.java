import java.lang.instrument.ClassFileTransformer;
import java.lang.instrument.Instrumentation;
import java.security.ProtectionDomain;

import org.objectweb.asm.ClassReader;
import org.objectweb.asm.ClassVisitor;
import org.objectweb.asm.ClassWriter;
import org.objectweb.asm.MethodVisitor;
import org.objectweb.asm.Opcodes;

/**
 * Defense-in-depth backup for org.eclipse.jdt.ls.core.internal.managers.
 * MavenProjectImporter#reset() (as of eclipse.jdt.ls, verified unchanged on
 * the master branch too): AbstractProjectImporter.initialize(File) only calls
 * reset() when rootFolder changes, and MavenProjectImporter.reset() never
 * clears the inherited "directories" field - so when ProjectsManager
 * .importProjects() iterates multiple independent Maven root paths (e.g.
 * several workspaceFolders passed via initializationOptions.workspaceFolders,
 * one per orphan/non-reactor module), applies(IProgressMonitor)
 * short-circuits on "directories != null" for every root path after the
 * first, silently reusing the FIRST root's stale scan results - so any Maven
 * module past the first root path never actually gets scanned.
 *
 * The real fix lives in a source-patched, locally rebuilt
 * org.eclipse.jdt.ls.core jar swapped into the jdtls install (see
 * ~/Git-projects/eclipse.jdt.ls-build, tag v1.54.0) - that rebuild also fixes
 * a second, deeper bug (getParentPomFile() returning null for a module
 * scanned in isolation when its pom.xml uses an empty <relativePath/>) that
 * this bytecode patch alone cannot reach. This agent stays installed purely
 * as a safety net: if jdtls ever gets reinstalled/updated (e.g. a Mason
 * reinstall) and silently reverts to the original, unpatched jar, this still
 * fixes the "directories" half of the bug at runtime without anyone noticing
 * the regression.
 */
public class MavenImporterPatchAgent {
    private static final String TARGET_CLASS =
        "org/eclipse/jdt/ls/core/internal/managers/MavenProjectImporter";
    private static final String FIELD_OWNER =
        "org/eclipse/jdt/ls/core/internal/AbstractProjectImporter";
    private static final String FIELD_NAME = "directories";
    private static final String FIELD_DESC = "Ljava/util/Collection;";

    public static void premain(String agentArgs, Instrumentation inst) {
        inst.addTransformer(new ClassFileTransformer() {
            @Override
            public byte[] transform(ClassLoader loader, String className,
                                     Class<?> classBeingRedefined,
                                     ProtectionDomain protectionDomain,
                                     byte[] classfileBuffer) {
                if (!TARGET_CLASS.equals(className)) {
                    return null;
                }
                try {
                    return patch(classfileBuffer);
                } catch (Throwable t) {
                    System.err.println(
                        "[jdtls-maven-importer-patch] FAILED to patch " + TARGET_CLASS + ": " + t);
                    return null;
                }
            }
        });
    }

    static byte[] patch(byte[] classfileBuffer) {
        ClassReader reader = new ClassReader(classfileBuffer);
        ClassWriter writer = new ClassWriter(reader, ClassWriter.COMPUTE_MAXS);
        ClassVisitor cv = new ClassVisitor(Opcodes.ASM9, writer) {
            @Override
            public MethodVisitor visitMethod(int access, String name, String descriptor,
                                              String signature, String[] exceptions) {
                MethodVisitor mv = super.visitMethod(access, name, descriptor, signature, exceptions);
                if ("reset".equals(name) && "()V".equals(descriptor)) {
                    return new MethodVisitor(Opcodes.ASM9, mv) {
                        @Override
                        public void visitCode() {
                            super.visitCode();
                            // this.directories = null;
                            mv.visitVarInsn(Opcodes.ALOAD, 0);
                            mv.visitInsn(Opcodes.ACONST_NULL);
                            mv.visitFieldInsn(Opcodes.PUTFIELD, FIELD_OWNER, FIELD_NAME, FIELD_DESC);
                        }
                    };
                }
                return mv;
            }
        };
        reader.accept(cv, 0);
        return writer.toByteArray();
    }
}
