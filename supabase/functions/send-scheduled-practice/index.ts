import { scheduledPracticeHandler } from '../_shared/scheduled-practice-push.ts';
import { pushRuntime } from '../_shared/practice-push-runtime.ts';
if(import.meta.main) {
  const {db,provider,operatorSecret}=pushRuntime(5000);
  Deno.serve(scheduledPracticeHandler(db,provider,operatorSecret));
}
