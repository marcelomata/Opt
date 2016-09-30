local IO = terralib.includec("stdio.h")
local adP = ad.ProblemSpec()
local P = adP.P
local N = opt.Dim("N",0)

local w_fitSqrt = adP:Param("w_fitSqrt", float, 0)
local w_regSqrt = adP:Param("w_regSqrt", float, 1)

-- TODO: pass in
local w_confSqrt = 1.0

local Offset = 			adP:Unknown("Offset", opt.float3,{N},2)			--vertex.xyz, rotation.xyz <- unknown
local Angle = 			adP:Unknown("Angle", opt.float3,{N},3)			--vertex.xyz, rotation.xyz <- unknown		
local RobustWeights = adP:Unknown("RobustWeights", float,{N},4)	
local UrShape = 	adP:Image("UrShape", opt.float3, {N},5)		--urshape: vertex.xyz
local Constraints = adP:Image("Constraints", opt.float3,{N},6)	--constraints
local ConstraintNormals = adP:Image("ConstraintNormals", opt.float3,{N},7)
local G = adP:Graph("G", 8, "v0", {N}, 9, "v1", {N}, 11)

P:UsePreconditioner(true)

local make_robust = true

function evalRot(CosAlpha, CosBeta, CosGamma, SinAlpha, SinBeta, SinGamma)
	return ad.Vector(
		CosGamma*CosBeta, 
		-SinGamma*CosAlpha + CosGamma*SinBeta*SinAlpha, 
		SinGamma*SinAlpha + CosGamma*SinBeta*CosAlpha,
		SinGamma*CosBeta,
		CosGamma*CosAlpha + SinGamma*SinBeta*SinAlpha,
		-CosGamma*SinAlpha + SinGamma*SinBeta*CosAlpha,
		-SinBeta,
		CosBeta*SinAlpha,
		CosBeta*CosAlpha)
end
	
function evalR(alpha, beta, gamma)
	return evalRot(ad.cos(alpha), ad.cos(beta), ad.cos(gamma), ad.sin(alpha), ad.sin(beta), ad.sin(gamma))
end
	
function mul(matrix, v)
	return ad.Vector(
			matrix(0)*v(0)+matrix(1)*v(1)+matrix(2)*v(2),
			matrix(3)*v(0)+matrix(4)*v(1)+matrix(5)*v(2),
			matrix(6)*v(0)+matrix(7)*v(1)+matrix(8)*v(2))
end

local terms = terralib.newlist()
	
--fitting
local x_fit = Offset(0)	--vertex-unknown : float3
local constraint = Constraints(0)						--target : float3
local robustWeight = RobustWeights(0)
local normal = ConstraintNormals(0)
local e_fit = normal:dot(x_fit - constraint)
e_fit = ad.select(ad.greatereq(constraint(0), -999999.9), e_fit, ad.Vector(0.0, 0.0, 0.0))
if make_robust then
    terms:insert(w_fitSqrt*robustWeight*e_fit)
else
    terms:insert(w_fitSqrt*e_fit)
end


--RobustWeight Penalty
if make_robust then
    local e_conf = 1-robustWeight*robustWeight
    terms:insert(w_confSqrt*e_conf)
end

--regularization
local x = Offset(G.v0)	--vertex-unknown : float3
local a = Angle(G.v0)  --rotation(alpha,beta,gamma) : float3
local R = evalR(a(0), a(1), a(2))			--rotation : float3x3
local xHat = UrShape(G.v0)					--uv-urshape : float3

local n = Offset(G.v1)
local ARAPCost = (x - n) - mul(R, (xHat - UrShape(G.v1)))

terms:insert(w_regSqrt*ARAPCost)

return adP:Cost(unpack(terms))

