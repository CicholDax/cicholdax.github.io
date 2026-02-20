// GPU ジッター頂点シェーダー（手書き風のブレ処理を GPU で実行）
// Bevy の mesh_view_bindings から view と globals を取得（group 0）
#import bevy_pbr::mesh_view_bindings as bindings

// 頂点入力（メッシュ属性から取得）
struct VertexInput {
    // ワールド空間の頂点位置
    @location(0) position: vec3<f32>,
    // x 成分に thickness（ブレ量）を格納（法線属性を流用）
    @location(1) normal: vec3<f32>,
    // 頂点カラー（RGBA）
    @location(2) color: vec4<f32>,
};

// 頂点出力（フラグメントシェーダーへ渡す）
struct VertexOutput {
    // クリップ空間の位置
    @builtin(position) clip_position: vec4<f32>,
    // 頂点カラー（フラグメントシェーダーへ補間して渡す）
    @location(0) color: vec4<f32>,
};

// PCG ハッシュ（GPU 向け高速疑似乱数、整数演算6回程度の軽量ハッシュ）
fn pcg_hash(input: u32) -> u32 {
    // LCG で状態を混ぜる
    var state = input * 747796405u + 2891336453u;
    // ビットシフトと XOR で出力を生成
    var word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    // 最終ハッシュ値を返す
    return (word >> 22u) ^ word;
}

// ハッシュ値を -1.0〜1.0 の float に変換する関数
fn hash_to_float(h: u32) -> f32 {
    // u32 の全範囲を 0.0〜1.0 に正規化してから -1.0〜1.0 にシフト
    return f32(h) / 4294967295.0 * 2.0 - 1.0;
}

// 頂点シェーダー本体
@vertex
fn vertex(input: VertexInput) -> VertexOutput {
    // 法線属性の x 成分から thickness（ブレ量）を読み取る
    let thickness = input.normal.x;
    // globals.time を離散化して 8Hz のカクカク感を出す（floor で切り捨て）
    let time_step = u32(floor(bindings::globals.time * 8.0));
    // 位置をグリッドに量子化（ビルボード回転による微小な座標変化を吸収する）
    let snap = 0.5;
    let sx = bitcast<u32>(floor(input.position.x / snap));
    let sy = bitcast<u32>(floor(input.position.y / snap));
    let sz = bitcast<u32>(floor(input.position.z / snap));
    // 量子化済み位置と時間ステップから一意なシードを生成
    let seed = sx ^ (sy * 1471u) ^ (sz * 6367u) ^ (time_step * 89513u);
    // X 軸のランダムオフセットを生成（-thickness 〜 +thickness）
    let offset_x = hash_to_float(pcg_hash(seed)) * thickness;
    // Y 軸のランダムオフセットを生成（シードを XOR で変えて独立した値にする）
    let offset_y = hash_to_float(pcg_hash(seed ^ 1u)) * thickness;
    // Z 軸のランダムオフセットを生成
    let offset_z = hash_to_float(pcg_hash(seed ^ 2u)) * thickness;
    // ジッター後のワールド座標を計算（元の位置 + ランダムオフセット）
    let world_pos = input.position + vec3<f32>(offset_x, offset_y, offset_z);
    // クリップ空間に変換（FuzzyRenderer は Transform::IDENTITY なのでモデル行列不要）
    var out: VertexOutput;
    out.clip_position = bindings::view.clip_from_world * vec4<f32>(world_pos, 1.0);

    // === 高さベース色付け（地形のみに適用） ===
    // 法線属性の z 成分から高さ色フラグを読み取る（1.0=有効、0.0=無効）
    let height_color_flag = input.normal.z;
    // 高さに応じた3色のグラデーション（水色→緑→山色）
    // 水色（水たまり）
    let water_color = vec3<f32>(0.3, 0.7, 1.0);
    // 緑色（草地ベース）
    let grass_color = vec3<f32>(0.15, 0.65, 0.15);
    // 山色（茶褐色）
    let mountain_color = vec3<f32>(0.55, 0.4, 0.25);
    // Y座標に基づいて水色→緑のブレンド係数を計算（Y=-5で完全水色、Y=3で完全緑）
    let water_to_grass = smoothstep(-5.0, 3.0, world_pos.y);
    // Y座標に基づいて緑→山色のブレンド係数を計算（Y=10で完全緑、Y=25で完全山色）
    let grass_to_mountain = smoothstep(10.0, 25.0, world_pos.y);
    // 水色→緑→山色の2段階グラデーションを合成
    let height_rgb = mix(mix(water_color, grass_color, water_to_grass), mountain_color, grass_to_mountain);
    // 高さ色が有効ならグラデーション色、無効なら元の頂点カラーを使用
    let base_rgb = mix(input.color.rgb, height_rgb, height_color_flag);

    // === 距離フォグ計算（フィールド地形のみに適用） ===
    // 法線属性の y 成分からフォグフラグを読み取る（1.0=フォグあり、0.0=なし）
    let fog_flag = input.normal.y;
    // カメラのワールド位置を取得
    let cam_pos = bindings::view.world_position;
    // カメラと頂点のXZ平面上の距離を計算（Y成分は無視）
    let dx = world_pos.x - cam_pos.x;
    let dz = world_pos.z - cam_pos.z;
    let xz_dist = sqrt(dx * dx + dz * dz);
    // smoothstep で滑らかなフェード係数を生成（20以内=1.0、100以遠=0.0）
    let fade = 1.0 - smoothstep(20.0, 100.0, xz_dist);
    // フォグ対象のみフェードを適用（非対象は 1.0 のまま、分岐なし）
    let fog_factor = mix(1.0, fade, fog_flag);
    // フォグ色
    let fog_color = vec3<f32>(0.0, 0.0, 0.0);
    // 高さ色適用済みのベースカラーをフォグ色に向かってフェード（アルファはそのまま）
    out.color = vec4<f32>(mix(fog_color, base_rgb, fog_factor), input.color.a);

    // 頂点出力を返す
    return out;
}

// フラグメントシェーダー本体（頂点カラーで描画）
@fragment
fn fragment(input: VertexOutput) -> @location(0) vec4<f32> {
    // 頂点カラーをそのまま出力
    return input.color;
}
