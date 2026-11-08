import { senderHandler } from '../_shared/practice-push.ts';
import { pushRuntime } from '../_shared/practice-push-runtime.ts';
if (import.meta.main) {
  const {db,provider,operatorSecret} = pushRuntime();
  Deno.serve(senderHandler(db,provider,operatorSecret));
}
