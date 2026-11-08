import { installationHandler } from '../_shared/practice-push.ts';
import { pushRuntime } from '../_shared/practice-push-runtime.ts';
if (import.meta.main) {
  const {db,clientHash} = pushRuntime();
  Deno.serve(installationHandler(db,clientHash));
}
