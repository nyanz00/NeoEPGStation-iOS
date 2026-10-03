#include <metal_stdlib>
using namespace metal;

struct CommentVertex { float2 position; float2 uv; };
struct CommentFragment { float4 position [[position]]; float2 uv; };

vertex CommentFragment commentVertex(uint index [[vertex_id]],
  const device CommentVertex *vertices [[buffer(0)]]) {
  CommentFragment output;
  output.position = float4(vertices[index].position, 0, 1);
  output.uv = vertices[index].uv;
  return output;
}

fragment float4 commentFragment(CommentFragment input [[stage_in]],
  texture2d<float> image [[texture(0)]], constant float &opacity [[buffer(0)]]) {
  constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
  // Core Graphics produces premultiplied alpha. Scale RGB and alpha together.
  return image.sample(linearSampler, input.uv) * opacity;
}
