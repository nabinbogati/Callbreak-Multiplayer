shader_type canvas_item;

// The wordmark's vertical gold gradient, applied to whatever text the Label
// draws. `height` is the label's own height, set from GoldText.
uniform vec4 top_color : source_color = vec4(1.0, 0.965, 0.847, 1.0);
uniform vec4 mid_color : source_color = vec4(0.941, 0.78, 0.369, 1.0);
uniform vec4 bottom_color : source_color = vec4(0.788, 0.573, 0.165, 1.0);
uniform float height = 40.0;

varying float local_y;

void vertex() {
	local_y = VERTEX.y;
}

void fragment() {
	float t = clamp(local_y / max(height, 1.0), 0.0, 1.0);
	vec3 c = t < 0.5 ? mix(top_color.rgb, mid_color.rgb, t * 2.0)
			: mix(mid_color.rgb, bottom_color.rgb, (t - 0.5) * 2.0);
	COLOR = vec4(c, COLOR.a);
}
