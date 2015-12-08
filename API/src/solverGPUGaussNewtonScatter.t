local S = require("std")
local util = require("util")
local dbg = require("dbg")
local C = util.C
local Timer = util.Timer
local positionForValidLane = util.positionForValidLane

local gpuMath = util.gpuMath

local function noHeader(pd)
	return quote end
end

local function noFooter(pd)
	return quote end
end

opt.BLOCK_SIZE = 16
local BLOCK_SIZE =  opt.BLOCK_SIZE

local FLOAT_EPSILON = `0.000001f 
-- GAUSS NEWTON (non-block version)
return function(problemSpec)

	local unknownElement = problemSpec:UnknownType().metamethods.typ
	local unknownType = problemSpec:UnknownType()

	local struct PlanData(S.Object) {
		plan : opt.Plan
		parameters : problemSpec:ParameterType(false)	--get the non-blocked version
		scratchF : &float
		debugDumpImage : &float
		debugCostImage : &float
		debugJTJImage : &float
		debugJTFImage : &float
		debugPreImage : &float


		delta : problemSpec:UnknownType()	--current linear update to be computed -> num vars
		r : problemSpec:UnknownType()		--residuals -> num vars	--TODO this needs to be a 'residual type'
		z : problemSpec:UnknownType()		--preconditioned residuals -> num vars	--TODO this needs to be a 'residual type'
		p : problemSpec:UnknownType()		--descent direction -> num vars
		Ap_X : problemSpec:UnknownType()	--cache values for next kernel call after A = J^T x J x p -> num vars
		preconditioner : problemSpec:UnknownType() --pre-conditioner for linear system -> num vars
		--rDotzOld : problemSpec:UnknownType()	--Old nominator (denominator) of alpha (beta) -> num vars	
		rDotzOld : problemSpec:InternalImage(float, unknownType.metamethods.W, unknownType.metamethods.H, false)	--Old nominator (denominator) of alpha (beta) -> num vars	
		
		scanAlpha : &float					-- tmp variable for alpha scan
		scanBeta : &float					-- tmp variable for alpha scan
		
		timer : Timer
		nIter : int				--current non-linear iter counter
		nIterations : int		--non-linear iterations
		lIterations : int		--linear iterations
	}
	
	
	
	local terra isBlockOnBoundary(gi : int, gj : int, width : uint, height : uint) : bool
		-- TODO meta program the bad based on the block size and stencil;
		-- TODO assert padX > stencil
		
		
		var padX : int
		var padY : int
		escape
			local blockSize = problemSpec:BlockSize()
		
			emit quote
				padX = int(blockSize)
				padY = int(blockSize)
			end
		end
		
		if gi - padX < 0 or gi + padX >= width or 
		   gj - padY < 0 or gj + padY >= height then
			return true
		end
		
		return false
	end
	

	local kernels = {}
	kernels.PCGInit1 = function(data)
		local terra PCGInit1GPU(pd : data.PlanData)
			var d = 0.0f -- init for out of bounds lanes
			var w : int, h : int
			if positionForValidLane(pd, "X", &w, &h) then
				-- residuum = J^T x -F - A x delta_0  => J^T x -F, since A x x_0 == 0
								
				var residuum : unknownElement = 0.0f
				var pre : unknownElement = 0.0f	
				if (not [problemSpec:EvalExclude(w,h,w,h,`pd.parameters)]) then 
								
					residuum, pre = data.problemSpec.functions.evalJTF.unknownfunction(w, h, w, h, pd.parameters)
					residuum = -residuum
					pd.r(w, h) = residuum
				end
				
				pd.preconditioner(w, h) = pre
				var p = pre*residuum	-- apply pre-conditioner M^-1			   
				pd.p(w, h) = p
			
				--d = residuum*p			-- x-th term of nominator for computing alpha and denominator for computing beta
				d = util.Dot(residuum,p) 
			end 
			d = util.warpReduce(d)	
			if (util.laneid() == 0) then
				util.atomicAdd(pd.scanAlpha, d)
			end
		end
		return { kernel = PCGInit1GPU, header = noHeader, footer = noFooter, mapMemberName = "X" }
	end
	
	kernels.PCGInit2 = function(data)
		local terra PCGInit2GPU(pd : data.PlanData)
			var w : int, h : int
			if positionForValidLane(pd, "X", &w, &h) and (not [problemSpec:EvalExclude(w,h,w,h,`pd.parameters)]) then
				pd.rDotzOld(w,h) = pd.scanAlpha[0]
				pd.delta(w,h) = 0.0f	--TODO check if we need that
			end
		end
		return { kernel = PCGInit2GPU, header = noHeader, footer = noFooter, mapMemberName = "X" }
	end
	
	kernels.PCGStep1 = function(data)
		local terra PCGStep1GPU(pd : data.PlanData)
			var d = 0.0f
			var w : int, h : int
			if positionForValidLane(pd, "X", &w, &h) and (not [problemSpec:EvalExclude(w,h,w,h,`pd.parameters)]) then
				var tmp : unknownElement = 0.0f
				 -- A x p_k  => J^T x J x p_k 
				tmp = data.problemSpec.functions.applyJTJ.unknownfunction(w, h, w, h, pd.parameters, pd.p)
				pd.Ap_X(w, h) = tmp								  -- store for next kernel call
				--d = pd.p(w, h)*tmp					              -- x-th term of denominator of alpha
				d = util.Dot(pd.p(w,h),tmp)
			end
			d = util.warpReduce(d)
			if (util.laneid() == 0) then
				util.atomicAdd(pd.scanAlpha, d)
			end
		end
		return { kernel = PCGStep1GPU, header = noHeader, footer = noFooter, mapMemberName = "X" }
	end
	
	kernels.PCGStep1_Graph = function(data)
		local terra PCGStep1GPU(pd : data.PlanData)
			var d = 0.0f
			var w : int, h : int
			if positionForValidLane(pd, "X", &w, &h) and (not [problemSpec:EvalExclude(w,h,w,h,`pd.parameters)]) then
				--var tmp : unknownElement = 0.0f
				-- A x p_k  => J^T x J x p_k 
				--tmp = data.problemSpec.functions.applyJTJ_Graph.unknownfunction(w, h, w, h, pd.parameters, pd.p)
				
				var w0, h0, w1, h1, d0, d1 = data.problemSpec.functions.applyJTJ_Graph.unknownfunction(w, h, w, h, pd.parameters, pd.p)
				
				atomicAdd(self.Ap_X(w0,h0), d0)		-- scatter store
				atomicAdd(self.Ap_X(w1,h1), d1)		-- scatter store
				
				d = util.Dot(self.p(w0,h0), d0) + util.Dot(self.p(w1,h1), d0)
			end
			d = util.warpReduce(d)
			if (util.laneid() == 0) then
				util.atomicAdd(pd.scanAlpha, d)
			end
		end
		return { kernel = PCGStep1GPU_Graph, header = noHeader, footer = noFooter, mapMemberName = "X" }
	end
	
	kernels.PCGStep2 = function(data)
		local terra PCGStep2GPU(pd : data.PlanData)
			var b = 0.0f 
			var w : int, h : int
			if positionForValidLane(pd, "X", &w, &h)  and (not [problemSpec:EvalExclude(w,h,w,h,`pd.parameters)]) then
				-- sum over block results to compute denominator of alpha
				var dotProduct : float = pd.scanAlpha[0]
				var alpha = 0.0f
				
				-- update step size alpha
				if dotProduct > FLOAT_EPSILON then alpha = pd.rDotzOld(w, h)/dotProduct end 
			
				pd.delta(w, h) = pd.delta(w, h)+alpha*pd.p(w,h)		-- do a decent step
				
				var r = pd.r(w,h)-alpha*pd.Ap_X(w,h)				-- update residuum
				pd.r(w,h) = r										-- store for next kernel call
			
				var z = pd.preconditioner(w,h)*r					-- apply pre-conditioner M^-1
				pd.z(w,h) = z;										-- save for next kernel call
				
				--b = z*r;											-- compute x-th term of the nominator of beta
				b = util.Dot(z,r)
			end
			b = util.warpReduce(b)
			if (util.laneid() == 0) then
				util.atomicAdd(pd.scanBeta, b)
			end
		end
		return { kernel = PCGStep2GPU, header = noHeader, footer = noFooter, mapMemberName = "X" }
	end
	
	kernels.PCGStep3 = function(data)
		local terra PCGStep3GPU(pd : data.PlanData)			
			var w : int, h : int
			if positionForValidLane(pd, "X", &w, &h) and (not [problemSpec:EvalExclude(w,h,w,h,`pd.parameters)]) then
				var rDotzNew : float =  pd.scanBeta[0]						-- get new nominator
				var rDotzOld : float = pd.rDotzOld(w,h)						-- get old denominator

				var beta : float = 0.0f			
						
				if rDotzOld > FLOAT_EPSILON then beta = rDotzNew/rDotzOld end	-- update step size beta
			
				pd.rDotzOld(w,h) = rDotzNew										-- save new rDotz for next iteration
				pd.p(w,h) = pd.z(w,h)+beta*pd.p(w,h)							-- update decent direction
			end
		end
		return { kernel = PCGStep3GPU, header = noHeader, footer = noFooter, mapMemberName = "X" }
	end
	
	kernels.PCGLinearUpdate = function(data)
		local terra PCGLinearUpdateGPU(pd : data.PlanData)
			var w : int, h : int
			if positionForValidLane(pd, "X", &w, &h) and (not [problemSpec:EvalExclude(w,h,w,h,`pd.parameters)]) then
				pd.parameters.X(w,h) = pd.parameters.X(w,h) + pd.delta(w,h)
			end
		end
		return { kernel = PCGLinearUpdateGPU, header = noHeader, footer = noFooter, mapMemberName = "X" }
	end
	
	
	kernels.computeCost = function(data)
		local terra computeCostGPU(pd : data.PlanData)
			
			var cost : float = 0.0f
			var w : int, h : int
			if util.positionForValidLane(pd, "X", &w, &h)  and (not [problemSpec:EvalExclude(w,h,w,h,`pd.parameters)]) then
				var params = pd.parameters				
				cost = cost + [float](data.problemSpec.functions.cost.unknownfunction(w, h, w, h, params))
			end

			cost = util.warpReduce(cost)
			if (util.laneid() == 0) then
			util.atomicAdd(pd.scratchF, cost)
			end
		end
		local function header(pd)
		    return quote
			C.cudaMemset(pd.scratchF, 0, sizeof(float))
		    end
		end
		local function footer(pd)
		    return quote
			var f : float
			C.cudaMemcpy(&f, pd.scratchF, sizeof(float), C.cudaMemcpyDeviceToHost)
			return f
		    end
		end
		
		return { kernel = computeCostGPU, header = header, footer = footer, mapMemberName = "X" }
	end

	if util.debugDumpInfo then
	kernels.dumpCostJTFAndPre = function(data)
		local terra dumpJTFAndPreGPU(pd : data.PlanData)
			var w : int, h : int
			if positionForValidLane(pd, "X", &w, &h) then
				-- residuum = J^T x -F - A x delta_0  => J^T x -F, since A x x_0 == 0
				
				var residuum : unknownElement = 0.0f
				var pre : unknownElement = 0.0f
				var cost : float = 0.0f

				cost = data.problemSpec.functions.cost.unknownfunction(w, h, w, h, pd.parameters)
				residuum, pre = data.problemSpec.functions.evalJTF.unknownfunction(w, h, w, h, pd.parameters)

				pd.debugCostImage[h*pd.parameters.X:W()+w] = cost
				[&unknownElement](pd.debugJTFImage)[h*pd.parameters.X:W()+w]  = residuum
				[&unknownElement](pd.debugPreImage)[h*pd.parameters.X:W()+w]  = pre
			end 
		end

		return { kernel = dumpJTFAndPreGPU, header = noHeader, footer = noFooter, mapMemberName = "X" }
	end

	kernels.dumpJTJ = function(data)
		local terra dumpJTJGPU(pd : data.PlanData)
			var d = 0.0f
			var w : int, h : int
			if positionForValidLane(pd, "X", &w, &h) then
				var tmp : unknownElement = 0.0f
				 -- A x p_k  => J^T x J x p_k 
				tmp = data.problemSpec.functions.applyJTJ.unknownfunction(w, h, w, h, pd.parameters, pd.p)
				[&unknownElement](pd.debugJTJImage)[h*pd.parameters.X:W()+w] = tmp
			end
		end
		return { kernel = dumpJTJGPU, header = noHeader, footer = noFooter, mapMemberName = "X" }
	end
	end

	local gpu = util.makeGPUFunctions(problemSpec, PlanData, kernels)

	---------------------------------------DEBUGGING FUNCTIONS------------------------------------------

	local terra initAllDebugImages(pd : &PlanData)
		C.printf("initAllDebugImages\n")
		dbg.initCudaImage(&pd.debugDumpImage,pd.parameters.X:W(), pd.parameters.X:H(),  1)
		dbg.initCudaImage(&pd.debugCostImage,pd.parameters.X:W(), pd.parameters.X:H(),  1)
		dbg.initCudaImage(&pd.debugJTJImage, pd.parameters.X:W(), pd.parameters.X:H(), sizeof([unknownElement]) / 4)
		dbg.initCudaImage(&pd.debugJTFImage, pd.parameters.X:W(), pd.parameters.X:H(), sizeof([unknownElement]) / 4)
		dbg.initCudaImage(&pd.debugPreImage, pd.parameters.X:W(), pd.parameters.X:H(), sizeof([unknownElement]) / 4)
	end




	local terra dumpImage(pd : &PlanData, ptr: &float, name : rawstring, nIter : int, lIter : int)
		if ([util.debugDumpInfo]) then
			var buffer : int8[64]
			C.sprintf(buffer, "%s_%d_%d.imagedump", name, nIter, lIter)
			dbg.imageWriteFromCuda(pd, ptr, 1, buffer)
		end
	end

	local function tableLength(T)
	   local count = 0
	   for _ in pairs(T) do count = count + 1 end
	   return count
	end


	---------------------------------------END DEBUGGING FUNCTIONS------------------------------------------

	
	local terra init(data_ : &opaque, images : &&opaque, graphSizes : &int32, edgeValues : &&opaque, xs : &&int32, ys : &&int32, params_ : &&opaque, solverparams : &&opaque)
	   var pd = [&PlanData](data_)
	   pd.timer:init()
	   pd.parameters = [util.getParameters(problemSpec, images, graphSizes,edgeValues,xs,ys,params_)]

	   pd.nIter = 0
	   
	   escape 
	      if util.debugDumpInfo then
		 emit quote
		    C.printf("initDebugImages\n")
		    initAllDebugImages(pd)
		 end
	      end
	   end
	   var buffer : int8[64]
	   escape
	      --TODO: Remove
 	     if false then
		 for key, entry in ipairs(problemSpec.parameters) do
		    if entry.kind == "image" then
		       print("" .. key .. " = imageTypes[" .. entry.idx .. "] = " .. tostring(entry.type))
		       local channel = 0 
		       local pixelType = entry.type.metamethods.typ
		       if pixelType == float then
			  channel = 1 
		       elseif pixelType == opt.float2 then
			  channel = 2
		       elseif pixelType == opt.float3 then
			  channel = 3
		       elseif pixelType == opt.float4 then
			  channel = 4
		       end
		       emit quote
			     C.sprintf(buffer, "arapTest%d.imagedump", entry.idx)
			     dbg.imageWriteFromCuda(pd, images[entry.idx], channel, buffer)
		       end

		    end
		 end

	      
	      end
	   end
           pd.nIterations = @[&int](solverparams[0])
	   pd.lIterations = @[&int](solverparams[1])
	end

	local terra step(data_ : &opaque, images : &&opaque, graphSizes : &int32, edgeValues : &&opaque, xs : &&int32, ys : &&int32, params_ : &&opaque, solverparams : &&opaque)
		var pd = [&PlanData](data_)
		pd.parameters = [util.getParameters(problemSpec, images, graphSizes,edgeValues,xs,ys,params_)]
		escape 
	    	if util.debugDumpInfo then
	    		emit quote

	    			-- Hack for SFS
	    			--var solveCount = ([&&uint32](params_))[39][0]
	    			if pd.nIter == 0 then
		    			C.printf("dumpingCostJTFAndPre\n")
		    			gpu.dumpCostJTFAndPre(pd)
		    			C.printf("saving\n")
		    			dbg.imageWriteFromCudaPrefix(pd.debugCostImage, pd.parameters.X:W(), pd.parameters.X:H(), 1, "cost")
		    			dbg.imageWriteFromCudaPrefix(pd.debugJTFImage, pd.parameters.X:W(), pd.parameters.X:H(), sizeof([unknownElement]) / 4, "JTF")
		    			dbg.imageWriteFromCudaPrefix(pd.debugPreImage, pd.parameters.X:W(), pd.parameters.X:H(), sizeof([unknownElement]) / 4, "Pre")
		    		end


	    		end
	    	end
		end

		if pd.nIter < pd.nIterations then
		    var startCost = gpu.computeCost(pd)
			logSolver("iteration %d, cost=%f\n", pd.nIter, startCost)

			C.cudaMemset(pd.scanAlpha, 0, sizeof(float))	--scan in PCGInit1 requires reset
			gpu.PCGInit1(pd)
			gpu.PCGInit2(pd)
			
			escape
				if util.debugDumpInfo then
		    		emit quote
			    		-- Hack for SFS
		    			--var solveCount = ([&&uint32](params_))[39][0]
		    			
		    			if pd.nIter == 0 then
			    			C.printf("dumpingJTJ\n")
			    			gpu.dumpJTJ(pd)
			    			C.printf("saving\n")
			    			dbg.imageWriteFromCudaPrefix(pd.debugJTJImage, pd.parameters.X:W(), pd.parameters.X:H(), sizeof([unknownElement]) / 4, "JTJ")
			    			return 0
			    		end
		    		end
		    	end
		    end

			for lIter = 0, pd.lIterations do
				

                C.cudaMemset(pd.scanAlpha, 0, sizeof(float))
				gpu.PCGStep1(pd)

				C.cudaMemset(pd.scanBeta, 0, sizeof(float))
				gpu.PCGStep2(pd)
				gpu.PCGStep3(pd)
			end
				
			gpu.PCGLinearUpdate(pd)
		    pd.nIter = pd.nIter + 1
		    return 1
		else
			escape
				if util.debugDumpInfo then
		    		emit quote
						dbg.imageWriteFromCudaPrefix([&float](pd.parameters.X.data), pd.parameters.X:W(), pd.parameters.X:H(), sizeof([unknownElement]) / 4, "result")

					end
				end
			end
			var finalCost = gpu.computeCost(pd)
			logSolver("final cost=%f\n", finalCost)
		    pd.timer:evaluate()
		    pd.timer:cleanup()
		    return 0
		end
	end

	local terra makePlan() : &opt.Plan
		var pd = PlanData.alloc()
		pd.plan.data = pd
		pd.plan.init,pd.plan.step = init,step

		pd.delta:initGPU()
		pd.r:initGPU()
		pd.z:initGPU()
		pd.p:initGPU()
		pd.Ap_X:initGPU()
		pd.preconditioner:initGPU()
		pd.rDotzOld:initGPU()
		
		C.cudaMalloc([&&opaque](&(pd.scanAlpha)), sizeof(float))
		C.cudaMalloc([&&opaque](&(pd.scanBeta)), sizeof(float))
		
		C.cudaMalloc([&&opaque](&(pd.scratchF)), sizeof(float))
		return &pd.plan
	end
	return makePlan
end