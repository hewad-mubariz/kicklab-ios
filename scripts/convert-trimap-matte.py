"""Reproducible local Core ML conversion of the evaluated ViTMatte checkpoint.

OUTPUT.mlpackage [edge=768]. No video or image data leaves the machine.
The model consumes normalized RGB plus trimap (0,128/255,1), NCHW.
"""
import json,sys,time
from pathlib import Path
import numpy as np
import torch
import coremltools as ct
from transformers import VitMatteForImageMatting
from transformers.models.vitdet import modeling_vitdet

model_id='hustvl/vitmatte-small-composition-1k'
revision='6a58ad7646403c1df626fbd746900aec7361ea1d'
destination=Path(sys.argv[1]);edge=int(sys.argv[2]) if len(sys.argv)>2 else 768
torch.set_num_threads(4)
class FixedEmbedding(torch.nn.Module):
 def __init__(self,original):
  super().__init__();self.projection=original.projection
  grid=edge//original.patch_size[0]
  with torch.no_grad():positions=original.get_absolute_positions(original.position_embeddings,True,grid,grid)
  self.register_buffer('positions',positions.permute(0,3,1,2).contiguous())
 def forward(self,pixels):return self.projection(pixels)+self.positions
class Alpha(torch.nn.Module):
 def __init__(self):
  super().__init__();self.model=VitMatteForImageMatting.from_pretrained(model_id,revision=revision).eval()
 def forward(self,pixels):return self.model(pixel_values=pixels).alphas
model=Alpha().eval();sample=torch.zeros(1,4,edge,edge)
start=time.monotonic()
with torch.inference_mode():
 expected=model(sample)
 model.model.backbone.embeddings=FixedEmbedding(model.model.backbone.embeddings)
 relative={}
 for layer in model.model.backbone.encoder.layer:
  grid=layer.window_size or edge//16
  for position in [layer.attention.rel_pos_h,layer.attention.rel_pos_w]:
   relative[id(position),grid,grid]=modeling_vitdet.get_rel_pos(grid,grid,position).detach()
 # Relative position tables are also input-independent at this fixed shape.
 modeling_vitdet.get_rel_pos=lambda q,k,p:relative[id(p),int(q),int(k)]
 torch.testing.assert_close(model(sample),expected,rtol=0,atol=0)
 traced=torch.jit.trace(model,sample,check_trace=False)
 # Fixed input geometry makes positional interpolation constant. Freeze it
 # before conversion instead of approximating unsupported bicubic sampling.
 traced=torch.jit.freeze(traced)
converted=ct.convert(traced,inputs=[ct.TensorType(name='pixels',shape=sample.shape,dtype=np.float32)],
 outputs=[ct.TensorType(name='alpha',dtype=np.float32)],minimum_deployment_target=ct.target.iOS17,
 compute_precision=ct.precision.FLOAT16,convert_to='mlprogram',skip_model_load=True)
converted.short_description='ViTMatte small: person-boundary refinement from RGB and a three-region trimap.'
converted.author='HUST Vision Lab; Core ML conversion by KickLab'
converted.license='Apache-2.0 (published Hugging Face checkpoint)'
converted.user_defined_metadata['source']=model_id
converted.user_defined_metadata['revision']=revision
converted.user_defined_metadata['preprocessing']='RGB=(byte/255-0.5)/0.5; trimap=byte/255; pad normalized NCHW with zero; clamp known trimap pixels after inference.'
converted.save(str(destination))
destination.with_suffix('.provenance.json').write_text(json.dumps({'source':model_id,'revision':revision,'edge':edge,
 'torch':torch.__version__,'coremltools':ct.__version__,'precision':'float16','seconds':time.monotonic()-start},indent=2))
print('Saved',destination,'seconds',time.monotonic()-start,flush=True)
