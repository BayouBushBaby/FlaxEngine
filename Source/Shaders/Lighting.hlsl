// Copyright (c) Wojciech Figat. All rights reserved.

#ifndef __LIGHTING__
#define __LIGHTING__

#include "./Flax/LightingCommon.hlsl"


float MicroShadowingTermReference(float visibility, float NdotL)
{
	float cosTheta = sqrt(1.0f - visibility);
	return step(cosTheta, NdotL);
}

 float pow5(float x)
 {
    float xx = x * x;
    return xx * xx * x;
 }

float CustomMicroShadow(float visibility, float NdotL, float gloss)
            {         
                 // Avoid divisions by 0.
	            if (frac(visibility) == 0.0)
		            return visibility;

                float sGloss = sin(gloss);

                float visrcp = lerp(0.75,4.0,sGloss);

	            float cosThetaPrime = sqrt(1.0 - lerp(pow5(visibility),visibility, sGloss));
	            float roughShadow = pow(saturate(NdotL / cosThetaPrime), visrcp * rcp(visibility));
  
                float ff = sin(saturate((gloss * 3.0) - 2.0));
                return pow(roughShadow, 1.0 + ff * lerp(0.,32.0, ff));
            
            }

float ApplyMicroShadow(GBufferSample gBuffer,float NdotL)
{        
    float visibility = gBuffer.AO;
    float roughness = gBuffer.Roughness;
	
    return CustomMicroShadow(visibility,NdotL, 1.0 - roughness);

    /*
    // Avoid divisions by 0.
	if (frac(visibility) == 0.0f)
		return visibility;

    //Adjust for roughness
    visibility = pow(visibility,roughness);



    //Inline pow5 to visibility
    float vp2 = visibility * visibility;
    float vp5 = vp2 * vp2 * visibility;    

	float cosThetaPrime = sqrt(1.0f - vp5);

    float roughResult = pow(saturate(NdotL / cosThetaPrime), 0.75f * rcp(visibility));
    
    //return roughResult;
    float smoothResult = MicroShadowingTermReference(visibility, NdotL);

	return lerp(smoothResult,roughResult,roughness);
    */
}



ShadowSample GetShadow(LightData lightData, GBufferSample gBuffer, float4 shadowMask)
{
    ShadowSample shadow;
#if LIGHTING_NO_SHADOW
    shadow.SurfaceShadow = gBuffer.AO;
    shadow.TransmissionShadow = 1.0f;
#else
    shadow.SurfaceShadow = gBuffer.AO * shadowMask.r;
    shadow.TransmissionShadow = shadowMask.g;
#endif
    return shadow;
}

LightSample StandardShading(GBufferSample gBuffer, float energy, float3 L, float3 V, half3 N)
{
    float3 diffuseColor = GetDiffuseColor(gBuffer);
    float3 H = normalize(V + L);
    float NoL = saturate(dot(N, L));
    float NoV = max(dot(N, V), 1e-5);
    float NoH = saturate(dot(N, H));
    float VoH = saturate(dot(V, H));

    LightSample lighting;
    lighting.Diffuse = Diffuse_Lambert(diffuseColor);
#if LIGHTING_NO_SPECULAR
    lighting.Specular = 0;
#else
    float3 specularColor = GetSpecularColor(gBuffer);
    float3 F = F_Schlick(specularColor, VoH);
    float D = D_GGX(gBuffer.Roughness, NoH) * energy;
    float Vis = Vis_SmithJointApprox(gBuffer.Roughness, NoV, NoL);
    // TODO: apply energy compensation to specular (1.0 + specularColor * (1.0 / PreIntegratedGF.y - 1.0))
    lighting.Specular = (D * Vis) * F;
#endif
    lighting.Transmission = 0;
    return lighting;
}

LightSample SubsurfaceShading(GBufferSample gBuffer, float energy, float3 L, float3 V, half3 N)
{
    LightSample lighting = StandardShading(gBuffer, energy, L, V, N);
#if defined(USE_GBUFFER_CUSTOM_DATA)
    // Fake effect of the light going through the material
    float3 subsurfaceColor = gBuffer.CustomData.rgb;
    float opacity = gBuffer.CustomData.a;
    float3 H = normalize(V + L);
    float inscatter = pow(saturate(dot(L, -V)), 12.1f) * lerp(3, 0.1f, opacity);
    float normalContribution = saturate(dot(N, H) * opacity + 1.0f - opacity);
    float backScatter = gBuffer.AO * normalContribution / (PI * 2.0f);
    lighting.Transmission = lerp(backScatter, 1, inscatter) * subsurfaceColor;
#endif
    return lighting;
}

LightSample FoliageShading(GBufferSample gBuffer, float energy, float3 L, float3 V, half3 N)
{
    LightSample lighting = StandardShading(gBuffer, energy, L, V, N);
#if defined(USE_GBUFFER_CUSTOM_DATA)
    // Fake effect of the light going through the thin foliage
    float3 subsurfaceColor = gBuffer.CustomData.rgb;
    float wrapNoL = saturate((-dot(N, L) + 0.5f) / 2.25);
    float VoL = dot(V, L);
    float scatter = D_GGX(0.36, saturate(-VoL));
    lighting.Transmission = subsurfaceColor * (wrapNoL * scatter);
#endif
    return lighting;
}

LightSample SurfaceShading(GBufferSample gBuffer, float energy, float3 L, float3 V, half3 N)
{
    switch (gBuffer.ShadingModel)
    {
    case SHADING_MODEL_UNLIT:
    case SHADING_MODEL_LIT:
        return StandardShading(gBuffer, energy, L, V, N);
    case SHADING_MODEL_SUBSURFACE:
        return SubsurfaceShading(gBuffer, energy, L, V, N);
    case SHADING_MODEL_FOLIAGE:
        return FoliageShading(gBuffer, energy, L, V, N);
    default:
        return (LightSample)0;
    }
}

float4 GetSkyLightLighting(LightData lightData, GBufferSample gBuffer, TextureCube ibl)
{
    // Get material diffuse color
    float3 diffuseColor = GetDiffuseColor(gBuffer);

    // Compute the preconvolved incoming lighting with the normal direction (apply ambient color)
    // Some data is packed, see C++ RendererSkyLightData::SetupLightData
    float mip = lightData.SourceLength;
#if LIGHTING_NO_DIRECTIONAL
    float3 uvw = float3(0, 0, 0);
#else
    float3 uvw = gBuffer.Normal;
#endif
    float3 diffuseLookup = ibl.SampleLevel(SamplerLinearClamp, uvw, mip).rgb * lightData.Color.rgb;
    diffuseLookup += float3(lightData.SpotAngles.rg, lightData.SourceRadius);

    // Fade out based on distance to capture
    float3 captureVector = gBuffer.WorldPos - lightData.Position;
    float captureVectorLength = length(captureVector);
    float normalizedDistanceToCapture = saturate(captureVectorLength / lightData.Radius);
    float distanceAlpha = 1.0 - smoothstep(0.6, 1, normalizedDistanceToCapture);

    // Calculate final light
    float3 color = diffuseLookup * diffuseColor;
    float luminance = Luminance(diffuseLookup);
    return float4(color, luminance) * (distanceAlpha * gBuffer.AO);
}

float4 GetLighting(float3 viewPos, LightData lightData, GBufferSample gBuffer, float4 shadowMask, bool isRadial, bool isSpotLight)
{
    float4 result = 0;
    float3 V = normalize(viewPos - gBuffer.WorldPos);
    float3 N = gBuffer.Normal;
    float3 L = lightData.Direction; // no need to normalize
    float NoL = saturate(dot(N, L));
    float3 toLight = lightData.Direction;

    // Calculate shadow
    ShadowSample shadow = GetShadow(lightData, gBuffer, shadowMask);

    // Calculate attenuation
    if (isRadial)
    {
        toLight = lightData.Position - gBuffer.WorldPos;
        float distanceSqr = dot(toLight, toLight);
        L = toLight * rsqrt(distanceSqr);
        float attenuation = 1;
        GetRadialLightAttenuation(lightData, isSpotLight, N, distanceSqr, 1, toLight, L, NoL, attenuation);
        shadow.SurfaceShadow *= attenuation;
        shadow.TransmissionShadow *= attenuation;
    }

#if !LIGHTING_NO_DIRECTIONAL
    // Directional shadowing
    shadow.SurfaceShadow *= NoL;
#endif

    BRANCH
    if (shadow.SurfaceShadow + shadow.TransmissionShadow > 0)
    {
        gBuffer.Roughness = max(gBuffer.Roughness, lightData.MinRoughness);
        float energy = AreaLightSpecular(lightData, gBuffer.Roughness, toLight, L, V, N);

        // Calculate direct lighting
        LightSample lighting = SurfaceShading(gBuffer, energy, L, V, N);
      
        // should ad a define if Microshadows are enabled for deferred 
        // forward will have to branch, should a Branch Attribute be applied?
        if(lightData.Dummy0 > 0.0)
        {
            float VoL = 1.0 - saturate(dot(V,L));
            lightData.Dummy0 *= VoL;
            shadow.SurfaceShadow *= lerp(1.0,ApplyMicroShadow(gBuffer, NoL),lightData.Dummy0);
        }
       

        // Calculate final light color
        float3 surfaceLight = (lighting.Diffuse + lighting.Specular) * shadow.SurfaceShadow;
        float3 subsurfaceLight = lighting.Transmission * shadow.TransmissionShadow;
        result.rgb = lightData.Color * (surfaceLight + subsurfaceLight);
        result.a = 1;
    }
    
    return result;
}

#endif
