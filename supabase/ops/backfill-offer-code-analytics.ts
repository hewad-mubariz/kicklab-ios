import { AppStoreServerAPIClient, Environment, SignedDataVerifier, GetTransactionHistoryVersion } from 'npm:@apple/app-store-server-library@3.1.0';
import { Buffer } from 'node:buffer';
// Run from the kicklab root. Input is the private JSON output of a read-only SQL query
// selecting environment, original_transaction_id from private.apple_subscriptions.
// The output is a reviewed SQL patch; this script never writes to Supabase.
const [inputPath, outputPath] = Deno.args;
if (!inputPath || !outputPath) throw new Error('Usage: <chains.json> <private-output.sql>');
const root = Deno.cwd();
const key = await Deno.readTextFile(root + '/config/local/SubscriptionKey_S5CUTFU6NQ.p8');
const roots = JSON.parse(await Deno.readTextFile(root + '/supabase/functions/_shared/apple-root-certificates.json'));
const client = new AppStoreServerAPIClient(key,'S5CUTFU6NQ','9b7830cc-2a57-43c6-813e-db0800261e24','com.juggledude',Environment.PRODUCTION);
const verifier = new SignedDataVerifier(roots.map((r:any)=>Buffer.from(r.der_base64,'base64')),true,Environment.PRODUCTION,'com.juggledude',6820780610);
const input = JSON.parse(await Deno.readTextFile(inputPath)).rows;
const checked:any[]=[]; const offers:Record<string,number>={}; let failed=0;
for (const row of input) {
  try {
    if (row.environment !== 'Production' || !/^[0-9]{1,30}$/.test(row.original_transaction_id)) throw new Error('Invalid chain');
    let revision: string|undefined; let more=true; let code=false; let pages=0;
    while(more) {
      if(++pages>100) throw new Error('Pagination limit');
      const history=await client.getTransactionHistory(row.original_transaction_id,revision,{},GetTransactionHistoryVersion.V2);
      if(history.bundleId!=='com.juggledude'||history.environment!==Environment.PRODUCTION) throw new Error('Unexpected app');
      for(const signed of history.signedTransactions??[]) {
        const tx=await verifier.verifyAndDecodeTransaction(signed);
        if(tx.originalTransactionId!==row.original_transaction_id || tx.inAppOwnershipType!=='PURCHASED') continue;
        if(tx.offerType===3 && ['com.hewad.juggledude.pro.monthly','com.hewad.juggledude.pro.yearly'].includes(tx.productId??'')) {code=true;offers[tx.offerIdentifier??'(unspecified)']=(offers[tx.offerIdentifier??'(unspecified)']??0)+1;}
      }
      more=history.hasMore===true;
      if(more&&(!history.revision||history.revision===revision)) throw new Error('Invalid pagination');
      revision=history.revision;
    }
    checked.push({...row,offer_code_redeemed:code});
  } catch(e) {failed++;const err=e as any;console.log(JSON.stringify({failed:true,status:err.httpStatusCode??null,appleError:err.apiError??null,kind:err.constructor.name}));}
}
if(failed) { console.log(JSON.stringify({checked:checked.length,failed})); Deno.exit(1); }
const ids = checked.filter(r=>r.offer_code_redeemed).map(r=>"'"+r.original_transaction_id+"'");
const sql = ids.length ? `begin;
update private.apple_subscriptions set offer_code_redeemed=true
where environment='Production' and original_transaction_id in (${ids.join(',')}) and not offer_code_redeemed;
commit;
` : '-- No verified offer-code records found.\n';
await Deno.writeTextFile(outputPath,sql,{mode:0o600});
console.log(JSON.stringify({chains:input.length,checked:checked.length,inviteChains:checked.filter(r=>r.offer_code_redeemed).length,offers,failed}));
