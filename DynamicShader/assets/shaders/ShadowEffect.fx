//=============================================================================
// ShadowEffect.fx
// 阴影渲染 Shader - 支持渐变透明度、高斯模糊和动态斜切
// 目标: MonoGame OpenGL (Shader Model 3.0)
//=============================================================================

//-----------------------------------------------------------------------------
// 参数
//-----------------------------------------------------------------------------

// 源纹理 (SpriteBatch 自动绑定到 register s0)
sampler2D SourceTexture : register(s0);

// 原始未模糊纹理（用于 Kawase Final Pass 的选择性混合）
texture OriginalTexture;
sampler2D OriginalSampler = sampler_state
{
    Texture = <OriginalTexture>;
    MinFilter = Linear;
    MagFilter = Linear;
    MipFilter = Linear;
    AddressU = Clamp;
    AddressV = Clamp;
};

// 模糊纹理（用于移轴效果的上采样混合）
texture BlurredTexture;
sampler2D BlurredSampler = sampler_state
{
    Texture = <BlurredTexture>;
    MinFilter = Linear;
    MagFilter = Linear;
    MipFilter = Linear;
    AddressU = Clamp;
    AddressV = Clamp;
};

// 阴影渐变查找表纹理
texture ShadowGradientLUTTexture;
sampler2D ShadowGradientLUT : register(s1) = sampler_state
{
    Texture = <ShadowGradientLUTTexture>;
    MinFilter = Linear;
    MagFilter = Linear;
    MipFilter = None;
    AddressU = Clamp;
    AddressV = Clamp;
};

// 堆叠阴影 Mask 纹理（用于 DownsampleWithStacked 合并渲染）
texture StackedMaskTexture;
sampler2D StackedMaskSampler = sampler_state
{
    Texture = <StackedMaskTexture>;
    MinFilter = Linear;
    MagFilter = Linear;
    MipFilter = None;
    AddressU = Clamp;
    AddressV = Clamp;
};


//-----------------------------------------------------------------------------
// [静态参数] 从 ModConfig 读取（游戏启动时同步一次）
//-----------------------------------------------------------------------------

// 阴影渐变参数
float GradientStart;              // 阴影渐变初始透明度 (0-1, 靠近物体处)
float GradientEnd;                // 阴影渐变结束透明度 (0-1, 远离物体处)
float ShadowEdgeBlurIntensity;   // 阴影边缘模糊强度

// 移轴效果参数
float FocusCenter;                // 移轴焦点中心位置 (0-1, 屏幕Y坐标, 0.5 = 中央)
float TiltShiftBlur;              // 移轴模糊强度
float TopBlurRangeRatio;          // 顶部模糊带宽比例 (0-1)
float BottomBlurRangeRatio;       // 底部模糊带宽比例 (0-1)

//-----------------------------------------------------------------------------
// [动态参数] 从 ShadowState 读取（每帧/每日更新）
//-----------------------------------------------------------------------------

// 阴影颜色（每日更新：根据天气调整）
float4 ShadowColor;               // 阴影颜色 (RGBA)

// 动态阴影参数（每帧更新：根据时间计算）
float NormalizedShearX;           // 归一化水平斜切因子（预计算 = ShearX / 100.0）
                                   // 表示阴影倾斜程度：正值向右，负值向左
                                   // 实际像素偏移 = NormalizedShearX * spriteHeight * shearFactor
float ShadowLengthScale;          // 阴影长度缩放 (1.0 = 原始长度，用于时间变化)

//-----------------------------------------------------------------------------
// [渲染上下文参数] 每帧由 C# 设置
//-----------------------------------------------------------------------------

float2 TexelSize;                 // 纹理像素尺寸 (用于模糊采样偏移计算)
float4x4 MatrixTransform;         // SpriteBatch 变换矩阵

//-----------------------------------------------------------------------------
// [建筑堆叠阴影参数] 用于方形建筑的阴影算法
//-----------------------------------------------------------------------------
float StackShearCompensation;     // 堆叠阴影最大斜切补偿（像素，通过Color.A归一化传递）
float BuildingBaseHeight;         // 建筑底座高度（像素），用于计算堆叠层的Y偏移
float StackStepSize;              // 堆叠阴影步长（像素）

//-----------------------------------------------------------------------------
// [Kawase Blur 参数] 用于 Dual Kawase Blur 算法
//-----------------------------------------------------------------------------
float KawaseOffset;               // Kawase 模糊采样偏移距离（通常从 0.5 开始，每次迭代递增）

//-----------------------------------------------------------------------------
// 顶点结构
//-----------------------------------------------------------------------------

struct VSInput
{
    float4 Position : POSITION0;
    float4 Color : COLOR0;
    float2 TexCoord : TEXCOORD0;
};

struct VSOutput
{
    float4 Position : SV_POSITION;
    float4 Color : COLOR0;
    float2 TexCoord : TEXCOORD0;
};

//-----------------------------------------------------------------------------
// 工具函数
//-----------------------------------------------------------------------------

/// <summary>
/// 计算精灵内的归一化 Y 坐标 (0 = 顶部, 1 = 底部)
/// </summary>
/// <param name="texCoordY">当前纹理坐标的 Y 值</param>
/// <param name="srcTop">源矩形顶部（归一化）</param>
/// <param name="srcBottom">源矩形底部（归一化）</param>
float CalculateNormalizedY(float texCoordY, float srcTop, float srcBottom)
{
    float range = srcBottom - srcTop;
    if (range > 0.001)
    {
        return saturate((texCoordY - srcTop) / range);
    }
    return 0.5;  // 默认值（范围无效时）
}

/// <summary>
/// 计算阴影渐变因子（使用 LUT 优化）
/// </summary>
float CalculateShadowGradient(float normalizedPos)
{
    // LUT 查表，替代 sqrt 计算
    return tex2D(ShadowGradientLUT, float2(normalizedPos, 0.5)).r;
};

//-----------------------------------------------------------------------------
// 顶点着色器 (SpriteBatch 兼容)
//-----------------------------------------------------------------------------

// 基础顶点着色器 - 直通（用于模糊等后处理）
VSOutput SpriteVertexShader(VSInput input)
{
    VSOutput output;
    output.Position = mul(input.Position, MatrixTransform);
    output.Color = input.Color;
    output.TexCoord = input.TexCoord;
    return output;
}

//-----------------------------------------------------------------------------
// 带斜切的顶点着色器
// 实现阴影角度变化：阴影底部固定，顶部水平偏移
//
// FlipVertically 后坐标说明：
// - TexCoord.Y=0: 原图顶部 → 屏幕下方（靠近物体）→ 固定不动
// - TexCoord.Y=1: 原图底部 → 屏幕上方（远离物体）→ 最大偏移
//-----------------------------------------------------------------------------

VSOutput ShearVertexShader(VSInput input)
{
    VSOutput output;
    output.Color = input.Color;
    output.TexCoord = input.TexCoord;
    
    float4 pos = input.Position;
    
    // 从 Color.RG 获取源矩形的 Y 边界（归一化到 0-1）
    float srcTop = input.Color.r;
    float srcBottom = input.Color.g;
    float normalizedHeight = input.Color.b;
    
    // 计算当前顶点在精灵内的相对位置（在VS中执行除法，仅4次）
    float normalizedV = CalculateNormalizedY(input.TexCoord.y, srcTop, srcBottom);
    
    // 恢复精灵的实际渲染高度（像素）
    float spriteHeight = normalizedHeight * 512.0;
    
    // FlipVertically 后：normalizedV=1 是近端（固定），normalizedV=0 是远端（最大偏移）
    float shearFactor = 1.0 - normalizedV;
    
    // 计算像素偏移：使用预计算的归一化斜切因子
    float pixelOffset = NormalizedShearX * spriteHeight * shearFactor;
    
    // 堆叠阴影斜切补偿：只应用于远端顶点
    float compensation = StackShearCompensation * shearFactor;
    
    pos.x += pixelOffset + compensation;
    
    // 阴影长度缩放：将远端顶点向近端收缩/扩张
    // shearFactor = 0 在近端（固定），= 1 在远端（最大缩放）
    pos.y -= (1.0 - ShadowLengthScale) * spriteHeight * shearFactor;
    
    // 应用 SpriteBatch 的变换矩阵
    output.Position = mul(pos, MatrixTransform);
    
    // 关键优化：将计算好的 normalizedV 写入 Color.b，供PS通过插值器获取
    // GPU会自动在顶点之间线性插值，PS直接读取插值后的值（零成本）
    output.Color.b = normalizedV;
    
    return output;
}

//-----------------------------------------------------------------------------
// Technique 1: 普通阴影 (NormalShadow)
// 有顶点斜切 + 像素级渐变，Color.RG 通道传递源矩形边界
//-----------------------------------------------------------------------------

float4 NormalShadowPS(VSOutput input) : COLOR
{
    float4 texColor = tex2D(SourceTexture, input.TexCoord);
    
    // clip() 当参数 < 0 时丢弃像素（阈值 0.15 过滤半透明软阴影像素）
    clip(texColor.a - 0.55);
    
    // 关键优化：直接从 Color.b 读取 VS 插值后的 normalizedY（无需计算！）
    // GPU已经自动在顶点之间线性插值，PS只需读取，零成本
    float normalizedV = input.Color.b;
    
    // 计算渐变因子
    float gradientFactor = CalculateShadowGradient(normalizedV);
    
    // 输出阴影颜色
    float4 result = ShadowColor;
    result.a *= gradientFactor * texColor.a;
    
    // 将 normalizedV 写入 B 通道，用于后续模糊 Pass
    result.b = normalizedV;
    
    return result;
}

technique NormalShadow
{
    pass P0
    {
        VertexShader = compile vs_3_0 ShearVertexShader();
        PixelShader = compile ps_3_0 NormalShadowPS();
    }
}

//-----------------------------------------------------------------------------
// Technique 2: 小型物体阴影 (SmallObjectShadow)
// 用于 Weed/Stone 等小型物体，无斜切 + 无渐变
//-----------------------------------------------------------------------------

float4 SmallObjectShadowPS(VSOutput input) : COLOR
{
    float4 texColor = tex2D(SourceTexture, input.TexCoord);
    
    clip(texColor.a - 0.15);
    
    float4 result = ShadowColor;
    result.a *= texColor.a;
    
    // 将 B 通道设为 1.0，防止被误判为需要模糊区域
    result.b = 1.0;
    
    return result;
}

technique SmallObjectShadow
{
    pass P0
    {
        VertexShader = compile vs_3_0 SpriteVertexShader();  // 无斜切
        PixelShader = compile ps_3_0 SmallObjectShadowPS();  // 无渐变
    }
}


//-----------------------------------------------------------------------------
// Technique 3: 水平高斯模糊 (HorizontalBlur)
//-----------------------------------------------------------------------------

// 9-tap 高斯权重 (sigma ≈ 2.0)
static const float Weights[5] = { 0.227027, 0.1945946, 0.1216216, 0.054054, 0.016216 };

float4 HorizontalBlurPS(VSOutput input) : COLOR
{
    // 采样中心像素
    float4 centerColor = tex2D(SourceTexture, input.TexCoord);
    
    // 获取 normalizedV (存储在 B 通道)
    float normalizedV = centerColor.b;
    
    // 跳过非阴影像素
    if (centerColor.a <= 0.0)
    {
        return centerColor;
    }
    
    // 提前退出：跳过不需要模糊的区域（收益巨大：节省9次纹理采样）
    if (normalizedV > 0.4)
    {
        return centerColor;
    }
    
    // 执行高斯模糊
    float4 blurredColor = centerColor * Weights[0];
    
    float2 offset1 = float2(TexelSize.x * 1.0 * ShadowEdgeBlurIntensity, 0);
    float2 offset2 = float2(TexelSize.x * 2.0 * ShadowEdgeBlurIntensity, 0);
    float2 offset3 = float2(TexelSize.x * 3.0 * ShadowEdgeBlurIntensity, 0);
    float2 offset4 = float2(TexelSize.x * 4.0 * ShadowEdgeBlurIntensity, 0);
    
    blurredColor += tex2D(SourceTexture, input.TexCoord + offset1) * Weights[1];
    blurredColor += tex2D(SourceTexture, input.TexCoord - offset1) * Weights[1];
    blurredColor += tex2D(SourceTexture, input.TexCoord + offset2) * Weights[2];
    blurredColor += tex2D(SourceTexture, input.TexCoord - offset2) * Weights[2];
    blurredColor += tex2D(SourceTexture, input.TexCoord + offset3) * Weights[3];
    blurredColor += tex2D(SourceTexture, input.TexCoord - offset3) * Weights[3];
    blurredColor += tex2D(SourceTexture, input.TexCoord + offset4) * Weights[4];
    blurredColor += tex2D(SourceTexture, input.TexCoord - offset4) * Weights[4];
    
    // 完全模糊区域(normalizedV < 0.3)：直接返回模糊结果，跳过lerp
    if (normalizedV < 0.2)
    {
        blurredColor.b = normalizedV;
        return blurredColor;
    }
    
    // 过渡区域(0.3-0.4)：计算权重并混合
    // Branchless权重计算：smoothstep自动处理边界
    float blurWeight = 1.0 - smoothstep(0.2, 0.4, normalizedV);
    float4 result = lerp(centerColor, blurredColor, blurWeight);
    
    // 保留 B 通道位置信息供 Vertical Pass 使用
    result.b = normalizedV;
    
    return result;
}

technique HorizontalBlur
{
    pass P0
    {
        PixelShader = compile ps_3_0 HorizontalBlurPS();
    }
}

//-----------------------------------------------------------------------------
// Technique 3: 垂直高斯模糊
//-----------------------------------------------------------------------------

float4 VerticalBlurPS(VSOutput input) : COLOR
{
    // 采样中心像素
    float4 centerColor = tex2D(SourceTexture, input.TexCoord);
    
    // 获取 normalizedV (存储在 B 通道)
    float normalizedV = centerColor.b;
    
    // 合并提前退出条件：非阴影像素或不需要模糊的区域
    if (centerColor.a <= 0.0 || normalizedV > 0.4)
    {
        centerColor.b = ShadowColor.b;
        return centerColor;
    }
    
    // 执行高斯模糊
    float4 blurredColor = centerColor * Weights[0];
    
    float2 offset1 = float2(0, TexelSize.y * 1.0 * ShadowEdgeBlurIntensity);
    float2 offset2 = float2(0, TexelSize.y * 2.0 * ShadowEdgeBlurIntensity);
    float2 offset3 = float2(0, TexelSize.y * 3.0 * ShadowEdgeBlurIntensity);
    float2 offset4 = float2(0, TexelSize.y * 4.0 * ShadowEdgeBlurIntensity);
    
    blurredColor += tex2D(SourceTexture, input.TexCoord + offset1) * Weights[1];
    blurredColor += tex2D(SourceTexture, input.TexCoord - offset1) * Weights[1];
    blurredColor += tex2D(SourceTexture, input.TexCoord + offset2) * Weights[2];
    blurredColor += tex2D(SourceTexture, input.TexCoord - offset2) * Weights[2];
    blurredColor += tex2D(SourceTexture, input.TexCoord + offset3) * Weights[3];
    blurredColor += tex2D(SourceTexture, input.TexCoord - offset3) * Weights[3];
    blurredColor += tex2D(SourceTexture, input.TexCoord + offset4) * Weights[4];
    blurredColor += tex2D(SourceTexture, input.TexCoord - offset4) * Weights[4];
    
    // 完全模糊区域(normalizedV < 0.3)：直接返回模糊结果，跳过lerp
    if (normalizedV < 0.2)
    {
        blurredColor.b = ShadowColor.b;
        return blurredColor;
    }
    
    // 过渡区域(0.2-0.4)：计算权重并混合
    // Branchless权重计算（逻辑同 HorizontalBlurPS）
    float blurWeight = 1.0 - smoothstep(0.2, 0.4, normalizedV);
    float4 result = lerp(centerColor, blurredColor, blurWeight);
    
    // 恢复 B 通道为原始阴影颜色
    result.b = ShadowColor.b;
    
    return result;
}

technique VerticalBlur
{
    pass P0
    {
        PixelShader = compile ps_3_0 VerticalBlurPS();
    }
}

//-----------------------------------------------------------------------------
// Technique 5: 方形建筑阴影 Mask 阶段 (SquareBuildingShadowMask)
// 第一阶段：有斜切 + 无渐变，生成纯 alpha Mask
// 输出：(globalY, 0, 0, alpha)
//-----------------------------------------------------------------------------

// 堆叠阴影专用顶点着色器（优化版）
VSOutput StackedShadowVS(VSInput input)
{
    VSOutput output;
    output.TexCoord = input.TexCoord;
    
    float4 pos = input.Position;
    
    // 从 Color 获取参数（由C#端预计算）
    float srcTop = input.Color.r;
    float srcBottom = input.Color.g;
    float layerBaseGlobalY = input.Color.b;  // 已预计算：(layer * stepSize) / totalStackHeight
    float layerSpan = input.Color.a;         // 已预计算：spriteRenderHeight / totalStackHeight
    
    // 优化：简化 normalizedV 计算（移除函数调用，内联并优化）
    float range = srcBottom - srcTop;
    float normalizedV = (input.TexCoord.y - srcTop) / max(range, 0.001);  // max()避免除零，比if分支快
    normalizedV = saturate(normalizedV);  // 确保在0-1范围，替代条件判断
    
    // 斜切计算
    float shearFactor = 1.0 - normalizedV;
    
    // 斜切偏移 = 基础偏移 + 层间补偿
    //   layerSpan * 512: 本层渲染高度（归一化到512参考值）
    pos.x += NormalizedShearX * shearFactor * (layerSpan + layerBaseGlobalY * 0.3) * 512.0;
    
    // 阴影长度缩放：将远端顶点向近端收缩/扩张
    pos.y -= (1.0 - ShadowLengthScale) * layerSpan * 512.0 * shearFactor;
    
    output.Position = mul(pos, MatrixTransform);
    
    // 关键优化：在VS中直接计算 globalY，PS只需读取插值后的值
    // 使用预计算的参数，只需一次乘法和一次加法
    float globalY = normalizedV * layerSpan + layerBaseGlobalY;
    
    // 将 globalY 存储到 Color.r，PS直接读取（GPU自动插值）
    output.Color.r = globalY;
    // 其他通道置0（PS不需要）
    output.Color.gba = float3(0, 0, 0);
    
    return output;
}

float4 SquareBuildingShadowMaskPS(VSOutput input) : COLOR
{
    float4 texColor = tex2D(SourceTexture, input.TexCoord);
    
    // 优化：使用 clip() 代替 if+discard（某些GPU上更高效）
    // clip() 当参数 < 0 时丢弃像素（阈值 0.15 过滤半透明软阴影像素）
    clip(texColor.a - 0.15);
    
    // 关键优化：直接从 Color.r 读取 VS 插值后的 globalY（无需计算！）
    // VS已经完成了除法和globalY计算，GPU自动插值到每个像素
    float globalY = input.Color.r;
    
    // 直接输出插值后的 globalY，供渐变阶段使用
    return float4(globalY, 0, 0, 1.0);
}

technique SquareBuildingShadowMask
{
    pass P0
    {
        VertexShader = compile vs_3_0 StackedShadowVS();
        PixelShader = compile ps_3_0 SquareBuildingShadowMaskPS();
    }
}

//-----------------------------------------------------------------------------
// Technique 6: 方形建筑阴影渐变阶段 (SquareBuildingShadowGradient)
// 第二阶段：对 Mask 应用基于屏幕 Y 坐标的渐变
//-----------------------------------------------------------------------------

float4 SquareBuildingShadowGradientPS(VSOutput input) : COLOR
{
    float4 maskColor = tex2D(SourceTexture, input.TexCoord);
    
    // 提前丢弃透明像素，避免无效计算和全屏 overdraw
    clip(maskColor.a - 0.15);
    
    // 从 R 通道读取全局归一化 Y 坐标
    float globalY = maskColor.r;
    
    // 用 ALU 计算渐变因子，替代 LUT 纹理查表
    // 消除 Dependent Texture Read（第二次采样 UV 依赖第一次采样结果导致的流水线气泡）
    // 公式与 LUT 预烘焙的曲线完全一致：lerp(GradientStart, GradientEnd, exp(-2.0 * x))
    float gradientFactor = lerp(GradientStart, GradientEnd, exp(-2.0 * globalY));
    
    // 输出阴影颜色
    float4 result = ShadowColor;
    result.a *= gradientFactor * maskColor.a;
    
    // 将 globalY 写入 B 通道，用于后续模糊 Pass
    result.b = globalY;
    
    return result;
}

technique SquareBuildingShadowGradient
{
    pass P0
    {
        VertexShader = compile vs_3_0 SpriteVertexShader();
        PixelShader = compile ps_3_0 SquareBuildingShadowGradientPS();
    }
}

//-----------------------------------------------------------------------------
// Technique 7-8: 移轴效果 (Tilt-Shift)
// 屏幕上下边缘应用模糊，中间区域保持清晰，模拟微缩模型摄影
//-----------------------------------------------------------------------------

/// <summary>
/// 计算移轴/景深模糊权重（in-shader 实时计算，替代 LUT 查表）
/// 焦点中心由 C# 端每帧动态设置（跟随玩家屏幕位置）
/// </summary>
float CalculateTiltShiftWeight(float screenY)
{
    // 计算距离焦点中心的距离
    float distFromCenter = abs(screenY - FocusCenter);
    
    // 根据上下位置选择对应的模糊范围比例
    float blurRangeRatio = (screenY < FocusCenter) ? TopBlurRangeRatio : BottomBlurRangeRatio;
    
    // 计算清晰带半宽
    float focusBandSize = (1.0 - blurRangeRatio) * 0.5;
    
    // 在清晰带内，权重为0（不模糊）
    if (distFromCenter <= focusBandSize)
    {
        return 0.0;
    }
    
    // 计算过渡范围
    float transitionRange = 0.5 - focusBandSize;
    
    // 避免除零
    if (transitionRange < 0.001)
    {
        return 1.0;
    }
    
    // 计算归一化的距离（0 = 清晰带边缘, 1 = 屏幕边缘）
    float normalizedDist = (distFromCenter - focusBandSize) / transitionRange;
    
    // 使用平方根函数让过渡更自然
    return sqrt(saturate(normalizedDist));
}

//-----------------------------------------------------------------------------
// Technique 7: 移轴水平模糊
//-----------------------------------------------------------------------------

float4 TiltShiftHorizontalPS(VSOutput input) : COLOR
{
    float blurWeight = CalculateTiltShiftWeight(input.TexCoord.y);
    
    if (blurWeight < 0.001)
    {
        return tex2D(SourceTexture, input.TexCoord);
    }
    
    float effectiveBlur = TiltShiftBlur * blurWeight;
    float2 texCoord = input.TexCoord;
    
    // 中心采样，后续复用避免重复采样
    float4 centerSample = tex2D(SourceTexture, texCoord);
    float4 color = centerSample * Weights[0];
    
    float2 offset1 = float2(TexelSize.x * 1.0 * effectiveBlur, 0);
    float2 offset2 = float2(TexelSize.x * 2.0 * effectiveBlur, 0);
    float2 offset3 = float2(TexelSize.x * 3.0 * effectiveBlur, 0);
    float2 offset4 = float2(TexelSize.x * 4.0 * effectiveBlur, 0);
    
    color += tex2D(SourceTexture, texCoord + offset1) * Weights[1];
    color += tex2D(SourceTexture, texCoord - offset1) * Weights[1];
    color += tex2D(SourceTexture, texCoord + offset2) * Weights[2];
    color += tex2D(SourceTexture, texCoord - offset2) * Weights[2];
    color += tex2D(SourceTexture, texCoord + offset3) * Weights[3];
    color += tex2D(SourceTexture, texCoord - offset3) * Weights[3];
    color += tex2D(SourceTexture, texCoord + offset4) * Weights[4];
    color += tex2D(SourceTexture, texCoord - offset4) * Weights[4];
    
    // 复用中心采样，避免重复纹理读取
    return lerp(centerSample, color, blurWeight);
}

technique TiltShiftHorizontal
{
    pass P0
    {
        PixelShader = compile ps_3_0 TiltShiftHorizontalPS();
    }
}

//-----------------------------------------------------------------------------
// Technique 8: 移轴垂直模糊
//-----------------------------------------------------------------------------

float4 TiltShiftVerticalPS(VSOutput input) : COLOR
{
    float blurWeight = CalculateTiltShiftWeight(input.TexCoord.y);
    
    if (blurWeight < 0.001)
    {
        return tex2D(SourceTexture, input.TexCoord);
    }
    
    float effectiveBlur = TiltShiftBlur * blurWeight;
    float2 texCoord = input.TexCoord;
    
    // 中心采样，后续复用避免重复采样
    float4 centerSample = tex2D(SourceTexture, texCoord);
    float4 color = centerSample * Weights[0];
    
    float2 offset1 = float2(0, TexelSize.y * 1.0 * effectiveBlur);
    float2 offset2 = float2(0, TexelSize.y * 2.0 * effectiveBlur);
    float2 offset3 = float2(0, TexelSize.y * 3.0 * effectiveBlur);
    float2 offset4 = float2(0, TexelSize.y * 4.0 * effectiveBlur);
    
    color += tex2D(SourceTexture, texCoord + offset1) * Weights[1];
    color += tex2D(SourceTexture, texCoord - offset1) * Weights[1];
    color += tex2D(SourceTexture, texCoord + offset2) * Weights[2];
    color += tex2D(SourceTexture, texCoord - offset2) * Weights[2];
    color += tex2D(SourceTexture, texCoord + offset3) * Weights[3];
    color += tex2D(SourceTexture, texCoord - offset3) * Weights[3];
    color += tex2D(SourceTexture, texCoord + offset4) * Weights[4];
    color += tex2D(SourceTexture, texCoord - offset4) * Weights[4];
    
    // 复用中心采样，避免重复纹理读取
    return lerp(centerSample, color, blurWeight);
}

technique TiltShiftVertical
{
    pass P0
    {
        PixelShader = compile ps_3_0 TiltShiftVerticalPS();
    }
}

//-----------------------------------------------------------------------------
// Technique 9: 降采样 (Downsample)
// 2×2 box filter 降采样，用于降采样模糊优化
//-----------------------------------------------------------------------------

float4 DownsamplePS(VSOutput input) : COLOR
{
    float2 uv = input.TexCoord;
    float2 offset = TexelSize * 0.5;
    
    // 2×2 区域采样（box filter）
    float4 color = tex2D(SourceTexture, uv + float2(-offset.x, -offset.y));
    color += tex2D(SourceTexture, uv + float2(+offset.x, -offset.y));
    color += tex2D(SourceTexture, uv + float2(-offset.x, +offset.y));
    color += tex2D(SourceTexture, uv + float2(+offset.x, +offset.y));
    
    // 简单平均
    return color * 0.25;
}

technique Downsample
{
    pass P0
    {
        VertexShader = compile vs_3_0 SpriteVertexShader();
        PixelShader = compile ps_3_0 DownsamplePS();
    }
}

//-----------------------------------------------------------------------------
// Technique 9.5: 合并降采样 + 堆叠阴影渐变 (DownsampleWithStacked)
// 将原 Phase 2（SquareBuildingShadowGradient 全屏 Pass）合并到降采样中
// 消除一次全屏 draw call 和对应的 Sbid 纹理延迟瓶颈
// 
// 原理：stackedMaskTarget 与 downsampledTarget 分辨率相同（rtWidth/2 × rtHeight/2），
// 可以在降采样时就地合成堆叠阴影渐变，避免先全屏写入 shadowTarget 再降采样的冗余往返
//-----------------------------------------------------------------------------

float4 DownsampleWithStackedPS(VSOutput input) : COLOR
{
    float2 uv = input.TexCoord;
    float2 offset = TexelSize * 0.5;
    
    // 标准 2×2 box filter 降采样（来自 shadowTarget，仅含 Normal + Simple 阴影）
    float4 color = tex2D(SourceTexture, uv + float2(-offset.x, -offset.y));
    color += tex2D(SourceTexture, uv + float2(+offset.x, -offset.y));
    color += tex2D(SourceTexture, uv + float2(-offset.x, +offset.y));
    color += tex2D(SourceTexture, uv + float2(+offset.x, +offset.y));
    color *= 0.25;
    
    // 采样堆叠阴影 Mask（与输出 RT 同分辨率，1:1 texel-to-pixel）
    float4 maskColor = tex2D(StackedMaskSampler, uv);
    
    // 合成堆叠阴影渐变（仅对有效 mask 像素）
    if (maskColor.a > 0.15)
    {
        float globalY = maskColor.r;
        float gradientFactor = lerp(GradientStart, GradientEnd, exp(-2.0 * globalY));
        float stackedAlpha = ShadowColor.a * gradientFactor;
        
        // 复现原 Phase 2 的硬件 AlphaBlend（Blend.One + Blend.InverseSourceAlpha）：
        //   final = src + dst * (1 - src.a)
        // 其中 src = (ShadowColor.r, ShadowColor.g, globalY, stackedAlpha)
        float invAlpha = 1.0 - stackedAlpha;
        float originalB = color.b;  // 保存原始 B，避免 double-blend
        color.rgb = ShadowColor.rgb + color.rgb * invAlpha;
        color.a = stackedAlpha + color.a * invAlpha;
        
        // B 通道写入 globalY（原 Phase 2 输出 result.b = globalY，硬件混合后 = globalY + dst.b*(1-sa)）
        color.b = globalY + originalB * invAlpha;
    }
    
    return color;
}

technique DownsampleWithStacked
{
    pass P0
    {
        VertexShader = compile vs_3_0 SpriteVertexShader();
        PixelShader = compile ps_3_0 DownsampleWithStackedPS();
    }
}

//-----------------------------------------------------------------------------
// Technique 11: 上采样 (Upsample)
// 使用硬件双线性插值上采样（通过 LinearClamp 采样器实现）
// 此 technique 主要用于显式标记，实际上采样只需设置正确的采样器
//-----------------------------------------------------------------------------

float4 UpsamplePS(VSOutput input) : COLOR
{
    // 直接采样，依赖 LinearClamp 采样器进行双线性插值
    return tex2D(SourceTexture, input.TexCoord);
}

technique Upsample
{
    pass P0
    {
        VertexShader = compile vs_3_0 SpriteVertexShader();
        PixelShader = compile ps_3_0 UpsamplePS();
    }
}

//-----------------------------------------------------------------------------
// Technique 12: Kawase Down Pass (Dual Kawase Blur 降采样)
// 采样 4 个对角像素，用于 Dual Kawase Blur 的降采样阶段
//-----------------------------------------------------------------------------

float4 KawaseDownPS(VSOutput input) : COLOR
{
    float2 uv = input.TexCoord;
    
    // 采样中心像素以获取 normalizedV
    float4 centerColor = tex2D(SourceTexture, uv);
    float normalizedV = centerColor.b;
    
    // 跳过完全透明的像素
    if (centerColor.a <= 0.0)
    {
        return centerColor;
    }
    
    // 执行 Kawase 采样（对所有像素执行，不要提前退出）
    float2 offset = TexelSize * KawaseOffset;
    
    float4 sum = 0;
    sum += tex2D(SourceTexture, uv + float2(-1, -1) * offset);
    sum += tex2D(SourceTexture, uv + float2(+1, -1) * offset);
    sum += tex2D(SourceTexture, uv + float2(-1, +1) * offset);
    sum += tex2D(SourceTexture, uv + float2(+1, +1) * offset);
    
    float4 blurredColor = sum * 0.25;
    
    // 保留 B 通道位置信息（从中心像素获取，不要从模糊结果获取）
    blurredColor.b = normalizedV;
    
    return blurredColor;
}

technique KawaseDown
{
    pass P0
    {
        VertexShader = compile vs_3_0 SpriteVertexShader();
        PixelShader = compile ps_3_0 KawaseDownPS();
    }
}

//-----------------------------------------------------------------------------
// Technique 13: Kawase Up Pass (Dual Kawase Blur 上采样)
// 采样 8 个周围像素，用于 Dual Kawase Blur 的上采样阶段
//-----------------------------------------------------------------------------

float4 KawaseUpPS(VSOutput input) : COLOR
{
    float2 uv = input.TexCoord;
    
    // 采样中心像素以获取 normalizedV
    float4 centerColor = tex2D(SourceTexture, uv);
    float normalizedV = centerColor.b;
    
    // 跳过完全透明的像素
    if (centerColor.a <= 0.0)
    {
        return centerColor;
    }
    
    // 执行 Kawase 上采样（对所有像素执行，不要提前退出）
    float2 offset = TexelSize * KawaseOffset;
    
    float4 sum = 0;
    
    // 对角 4 个像素（权重 2.0）
    sum += tex2D(SourceTexture, uv + float2(-1, -1) * offset) * 2.0;
    sum += tex2D(SourceTexture, uv + float2(+1, -1) * offset) * 2.0;
    sum += tex2D(SourceTexture, uv + float2(-1, +1) * offset) * 2.0;
    sum += tex2D(SourceTexture, uv + float2(+1, +1) * offset) * 2.0;
    
    // 上下左右 4 个像素（权重 1.0）
    sum += tex2D(SourceTexture, uv + float2(-1,  0) * offset);
    sum += tex2D(SourceTexture, uv + float2(+1,  0) * offset);
    sum += tex2D(SourceTexture, uv + float2( 0, -1) * offset);
    sum += tex2D(SourceTexture, uv + float2( 0, +1) * offset);
    
    float4 blurredColor = sum / 12.0;
    
    // 保留 B 通道位置信息（从中心像素获取）
    blurredColor.b = normalizedV;
    
    return blurredColor;
}

technique KawaseUp
{
    pass P0
    {
        VertexShader = compile vs_3_0 SpriteVertexShader();
        PixelShader = compile ps_3_0 KawaseUpPS();
    }
}

//-----------------------------------------------------------------------------
// Technique 13.5: Kawase Up Final Pass (最后一次上采样，恢复 B 通道)
// 用于 Dual Kawase Blur 的最后一次上采样，恢复 B 通道为阴影颜色
//-----------------------------------------------------------------------------

float4 KawaseUpFinalPS(VSOutput input) : COLOR
{
    float2 uv = input.TexCoord;
    
    // 采样模糊后的结果（从 mipChain[0]，已经完全模糊）
    float4 blurredColor = tex2D(SourceTexture, uv);
    
    // 采样原始未模糊的阴影（从 shadowTarget）
    float4 originalColor = tex2D(OriginalSampler, uv);
    
    // 获取 normalizedV（从原始阴影的 B 通道）
    float normalizedV = originalColor.b;
    
    // 跳过完全透明的区域（原始阴影中没有像素）
    if (originalColor.a <= 0.0)
    {
        // 但模糊可能扩散到这里，所以返回模糊结果而不是原始透明
        // 只有当模糊结果也是透明时才返回透明
        if (blurredColor.a <= 0.0)
        {
            return float4(0, 0, 0, 0);
        }
        // 模糊扩散到了空白区域，返回模糊结果并恢复 B 通道
        blurredColor.b = ShadowColor.b;
        return blurredColor;
    }
    
    // SimpleShadow (normalizedV = 1.0) 和 NormalShadow 顶部 (normalizedV > 0.4)：
    // 不应该被模糊，返回原始颜色
    if (normalizedV > 0.4)
    {
        originalColor.b = ShadowColor.b;
        return originalColor;
    }
    
    // 完全模糊区域 (normalizedV < 0.3)：返回模糊结果
    if (normalizedV < 0.3)
    {
        blurredColor.b = ShadowColor.b;
        return blurredColor;
    }
    
    // 过渡区域 (0.3-0.4)：在原始和模糊之间渐变混合
    float blurWeight = 1.0 - smoothstep(0.3, 0.4, normalizedV);
    float4 result = lerp(originalColor, blurredColor, blurWeight);
    result.b = ShadowColor.b;
    
    return result;
}

technique KawaseUpFinal
{
    pass P0
    {
        VertexShader = compile vs_3_0 SpriteVertexShader();
        PixelShader = compile ps_3_0 KawaseUpFinalPS();
    }
}

//-----------------------------------------------------------------------------
// Technique 14: 移轴混合上采样 (TiltShiftUpsampleBlend)
// 使用 TiltShiftWeightLUT 混合原图和模糊图
//-----------------------------------------------------------------------------

// 原图纹理（重用第 15-24 行定义的 OriginalTexture 和 OriginalSampler）

float4 TiltShiftUpsampleBlendPS(VSOutput input) : COLOR
{
    // 采样模糊图（来自 Kawase 最后一级 Mip）
    float4 blurredColor = tex2D(SourceTexture, input.TexCoord);
    
    // 采样原图
    float4 originalColor = tex2D(OriginalSampler, input.TexCoord);
    
    // 获取模糊权重（基于屏幕Y坐标）
    float blurWeight = CalculateTiltShiftWeight(input.TexCoord.y);
    
    // 混合原图和模糊图
    return lerp(originalColor, blurredColor, blurWeight);
}

technique TiltShiftUpsampleBlend
{
    pass P0
    {
        VertexShader = compile vs_3_0 SpriteVertexShader();
        PixelShader = compile ps_3_0 TiltShiftUpsampleBlendPS();
    }
}

//-----------------------------------------------------------------------------
// Technique 15: 移轴降采样 (TiltShiftDownsample)
// 2×2 box filter 降采样（简单版本，不带权重）
//-----------------------------------------------------------------------------

float4 TiltShiftDownsamplePS(VSOutput input) : COLOR
{
    float2 uv = input.TexCoord;
    float2 offset = TexelSize * 0.5;
    
    // 2×2 区域采样（box filter）
    float4 color = tex2D(SourceTexture, uv + float2(-offset.x, -offset.y));
    color += tex2D(SourceTexture, uv + float2(+offset.x, -offset.y));
    color += tex2D(SourceTexture, uv + float2(-offset.x, +offset.y));
    color += tex2D(SourceTexture, uv + float2(+offset.x, +offset.y));
    
    // 简单平均
    return color * 0.25;
}

technique TiltShiftDownsample
{
    pass P0
    {
        VertexShader = compile vs_3_0 SpriteVertexShader();
        PixelShader = compile ps_3_0 TiltShiftDownsamplePS();
    }
}

//-----------------------------------------------------------------------------
// Technique 16: 移轴上采样混合 (TiltShiftUpsample)
// 混合原图和模糊图，根据移轴权重
//-----------------------------------------------------------------------------

float4 TiltShiftUpsamplePS(VSOutput input) : COLOR
{
    // 采样原图（全分辨率）
    float4 originalColor = tex2D(SourceTexture, input.TexCoord);
    
    // 采样模糊图（降采样后的，使用线性插值自动上采样）
    float4 blurredColor = tex2D(BlurredSampler, input.TexCoord);
    
    // 获取移轴权重（基于屏幕Y坐标）
    float blurWeight = CalculateTiltShiftWeight(input.TexCoord.y);
    
    // 混合原图和模糊图
    return lerp(originalColor, blurredColor, blurWeight);
}

technique TiltShiftUpsample
{
    pass P0
    {
        VertexShader = compile vs_3_0 SpriteVertexShader();
        PixelShader = compile ps_3_0 TiltShiftUpsamplePS();
    }
}

//-----------------------------------------------------------------------------
// Technique 17: 纯高斯模糊 - 水平 (用于移轴效果)
// 不带阴影特定逻辑的纯净高斯模糊
//-----------------------------------------------------------------------------

float4 PureHorizontalBlurPS(VSOutput input) : COLOR
{
    float4 color = tex2D(SourceTexture, input.TexCoord) * Weights[0];
    
    // 使用 TiltShiftBlur 参数控制模糊强度
    float2 offset1 = float2(TexelSize.x * 1.0 * TiltShiftBlur, 0);
    float2 offset2 = float2(TexelSize.x * 2.0 * TiltShiftBlur, 0);
    float2 offset3 = float2(TexelSize.x * 3.0 * TiltShiftBlur, 0);
    float2 offset4 = float2(TexelSize.x * 4.0 * TiltShiftBlur, 0);
    
    color += tex2D(SourceTexture, input.TexCoord + offset1) * Weights[1];
    color += tex2D(SourceTexture, input.TexCoord - offset1) * Weights[1];
    color += tex2D(SourceTexture, input.TexCoord + offset2) * Weights[2];
    color += tex2D(SourceTexture, input.TexCoord - offset2) * Weights[2];
    color += tex2D(SourceTexture, input.TexCoord + offset3) * Weights[3];
    color += tex2D(SourceTexture, input.TexCoord - offset3) * Weights[3];
    color += tex2D(SourceTexture, input.TexCoord + offset4) * Weights[4];
    color += tex2D(SourceTexture, input.TexCoord - offset4) * Weights[4];
    
    return color;
}

technique PureHorizontalBlur
{
    pass P0
    {
        VertexShader = compile vs_3_0 SpriteVertexShader();
        PixelShader = compile ps_3_0 PureHorizontalBlurPS();
    }
}

//-----------------------------------------------------------------------------
// Technique 18: 纯高斯模糊 - 垂直 (用于移轴效果)
// 不带阴影特定逻辑的纯净高斯模糊
//-----------------------------------------------------------------------------

float4 PureVerticalBlurPS(VSOutput input) : COLOR
{
    float4 color = tex2D(SourceTexture, input.TexCoord) * Weights[0];
    
    // 使用 TiltShiftBlur 参数控制模糊强度
    float2 offset1 = float2(0, TexelSize.y * 1.0 * TiltShiftBlur);
    float2 offset2 = float2(0, TexelSize.y * 2.0 * TiltShiftBlur);
    float2 offset3 = float2(0, TexelSize.y * 3.0 * TiltShiftBlur);
    float2 offset4 = float2(0, TexelSize.y * 4.0 * TiltShiftBlur);
    
    color += tex2D(SourceTexture, input.TexCoord + offset1) * Weights[1];
    color += tex2D(SourceTexture, input.TexCoord - offset1) * Weights[1];
    color += tex2D(SourceTexture, input.TexCoord + offset2) * Weights[2];
    color += tex2D(SourceTexture, input.TexCoord - offset2) * Weights[2];
    color += tex2D(SourceTexture, input.TexCoord + offset3) * Weights[3];
    color += tex2D(SourceTexture, input.TexCoord - offset3) * Weights[3];
    color += tex2D(SourceTexture, input.TexCoord + offset4) * Weights[4];
    color += tex2D(SourceTexture, input.TexCoord - offset4) * Weights[4];
    
    return color;
}

technique PureVerticalBlur
{
    pass P0
    {
        VertexShader = compile vs_3_0 SpriteVertexShader();
        PixelShader = compile ps_3_0 PureVerticalBlurPS();
    }
}

//-----------------------------------------------------------------------------
// Technique 19: 移轴 Alpha 输出（用于硬件混合）
// 采样模糊图，将移轴权重作为 Alpha 输出，利用硬件混合器完成最终混合
//-----------------------------------------------------------------------------

float4 TiltShiftAlphaOutputPS(VSOutput input) : COLOR
{
    // 计算移轴权重
    float blurWeight = CalculateTiltShiftWeight(input.TexCoord.y);
    
    // 如果权重接近0（清晰区域），输出完全透明，不影响原图
    if (blurWeight < 0.001)
    {
        return float4(0, 0, 0, 0);
    }
    
    // 采样模糊图（降采样后的，LinearClamp 自动上采样）
    float4 blurredColor = tex2D(SourceTexture, input.TexCoord);
    
    // 将权重作为 Alpha 输出（不预乘，让混合器处理）
    blurredColor.a = blurWeight;
    
    return blurredColor;
}

technique TiltShiftAlphaOutput
{
    pass P0
    {
        VertexShader = compile vs_3_0 SpriteVertexShader();
        PixelShader = compile ps_3_0 TiltShiftAlphaOutputPS();
    }
}
