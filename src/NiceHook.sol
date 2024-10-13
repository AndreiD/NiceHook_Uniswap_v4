// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {Position} from "v4-core/src/libraries/Position.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";

import {console} from "forge-std/console.sol"; //TODO: remove me on deployment

contract NiceHook is BaseHook {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using SafeCast for *;

    IPoolManager immutable manager;
    bytes32 public root; // Merkle root
    bool public isKYCEnabled = false; //enables or disables kyc requirement for swapping
    bool public isReferralEnabled = false; //enables or disables referals
    bool public isSandwichProtected = false; //enables or disables sandwich protection
    bool public isBigLPNoFee = false; //enables or disables zero fee on big LPs    

    uint256 public buyFee = 500; // the buy fee should be lower to incentivize buying
    bool private inBuy; //track buying and selling
    mapping(address => uint256) public providerPoints; // Mapping to store accounts that qualify for zero fees
    uint256 public minimumPointsForZeroFee; // Minimum liquidity required for zero fees
    uint256 private startTimestamp;
    uint128 public constant START_FEE = 100000; //10%
    uint128 public constant REGULAR_FEE = 1_000; //0.1%
    uint128 public constant ZERO_FEE = 1_00; //0.01%
    // 9.9% for sandwichers
    uint128 public constant MEV_FEE = 100000; //10%
    // Start at 10% fee, decaying at a rate of 0.00001% (1 in uint128 terms) per second.
    uint128 public constant decayRate = 1; // 0.00001% per second

    // Keeping track of user => referrer
    mapping(address => address) public referredBy;

    // Map PoolId -> User -> Timestamp
    mapping(PoolId => mapping(address => uint256)) public buyDataMap; //TODO: transform all state variables to maps unique to a pool

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function setKYCEnabled(bool isEnabled) external {
        //TODO: ATTENTION -> not protected
        require(!isReferralEnabled, "cannot use referral and kyc at the same time");
        isKYCEnabled = isEnabled;
    }

    function setIsReferalEnabled(bool isEnabled) external {
        //TODO: ATTENTION -> not protected
        require(!isReferralEnabled, "cannot use referral and kyc at the same time");
        isReferralEnabled = isEnabled;
    }

    function setIsLPZeroFee(bool isEnabled, uint256 minPoints) external {
        //TODO: ATTENTION -> not protected
        isBigLPNoFee = isEnabled;
        minimumPointsForZeroFee = minPoints;
    }

    function setSandwichProtected(bool isEnabled) external {
        //TODO: ATTENTION -> not protected
        isSandwichProtected = isEnabled;
    }

    function setBuyFee(uint256 newBuyFee) external {
        //TODO: ATTENTION -> not protected
        require(newBuyFee < 10_000, "not above 1 percent");
        buyFee = newBuyFee;
    }

    // Helper function for demonstration
    function setMerkleRoot(bytes32 newRoot) external {
        //TODO: ATTENTION -> not protected
        root = newRoot;
    }

    // -----------------------------------------------
    // NOTE: see IHooks.sol for function documentation
    // -----------------------------------------------

    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata hookData)
        external
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        console.log("before swap triggered");
        address referree; 
        address referrer;

        if (isReferralEnabled) {
            console.log("referral system is enabled");
           (referrer, referree) = abi.decode(hookData, (address, address));
             referredBy[referree] = referrer;
             console.log("referree:", referree);
             console.log("referrer:", referrer);
        }

        if (isKYCEnabled) {
            console.log("kyc is enabled");
            // Extract user's address & proof from hookData
            (address user, bytes32[] memory proof) = abi.decode(hookData, (address, bytes32[]));
            console.log("kyc user passed", user);
            // Verify the Merkle proof
            require(_isWhitelisted(user, proof), "not whitelisted");
        }

        if (isSandwichProtected) {
            console.log("sandwich protection enabled");
            if (buyDataMap[key.toId()][tx.origin] + 1 > block.timestamp) {
                console.log("sandwich detected!!!!");
                return (
                    BaseHook.beforeSwap.selector,
                    BeforeSwapDeltaLibrary.ZERO_DELTA,
                    uint24(MEV_FEE) | LPFeeLibrary.OVERRIDE_FEE_FLAG
                );
            }
        }
        console.log("sandwich was not detected");

        inBuy = params.zeroForOne;
        console.log("in buy?", inBuy);
        if (inBuy) {

            //add points if referral is enabled
            if (isReferralEnabled) {
                if (referredBy[referree] != address(0) && referrer != address(0)) {
                           console.log("todo: LOGIC to give rewards to this referree", referree);
                }
            }

            return (
                BaseHook.beforeSwap.selector,
                BeforeSwapDeltaLibrary.ZERO_DELTA,
                uint24(buyFee) | LPFeeLibrary.OVERRIDE_FEE_FLAG
            );
        }

        //it's a sell, tax it
        uint256 _currentFee;
        unchecked {
            uint256 timeElapsed = block.timestamp - startTimestamp;
            _currentFee =
                timeElapsed > 495000 ? uint256(REGULAR_FEE) : (uint256(START_FEE) - (timeElapsed * decayRate)) / 10;
            console.log("_currentFee", _currentFee);
        }

        //big LP providers don't pay tax on swaps
        if(isBigLPNoFee){
           if(providerPoints[msg.sender] >= minimumPointsForZeroFee){
            return (
                BaseHook.beforeSwap.selector,
                BeforeSwapDeltaLibrary.ZERO_DELTA,
                uint24(ZERO_FEE) | LPFeeLibrary.OVERRIDE_FEE_FLAG
            );
           }
        }

        // to override the LP fee, its 2nd bit must be set for the override to apply
        console.log("swap currentFee", _currentFee);
        return (
            BaseHook.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            uint24(_currentFee) | LPFeeLibrary.OVERRIDE_FEE_FLAG
        );
    }

    function afterSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata, BalanceDelta, bytes calldata)
        external
        override
        returns (bytes4, int128)
    {
        PoolId poolId = key.toId();
        buyDataMap[poolId][tx.origin] = block.timestamp;
        return (BaseHook.afterSwap.selector, 0);
    }

    function afterInitialize(address, PoolKey calldata key, uint160, int24, bytes calldata)
        external
        override
        returns (bytes4)
    {
        // after pool is initialized, set the initial fee
        console.log("after initialize called");
        startTimestamp = block.timestamp;
        poolManager.updateDynamicLPFee(key, uint24(START_FEE));
        //console.log("initial fee is set");

        return BaseHook.afterInitialize.selector;
    }

    function _isWhitelisted(address user, bytes32[] memory proof) internal view returns (bool) {
        bytes32 leaf = keccak256(abi.encodePacked(user));
        return MerkleProof.verify(proof, root, leaf);
    }

    /**
     * Hook called after liquidity is added to the pool.
     * If the added liquidity exceeds the threshold, the provider gets zero fees.
     */
   function afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata
    ) external override returns (bytes4, BalanceDelta) {
        console.log("afterAddLiquidity called");
        
        uint256 pointsForAddingLiquidity = uint256(int256(-delta.amount0()));
        console.log("points added", pointsForAddingLiquidity);
                
        providerPoints[sender] = providerPoints[sender] + pointsForAddingLiquidity;
 
        return (BaseHook.afterAddLiquidity.selector, delta);
    }

    /**
     * Hook called after liquidity is removed from the pool.
     * If the liquidity falls below the threshold, the provider loses zero fee eligibility.
     */
    function afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata
    ) external override returns (bytes4, BalanceDelta) {
        console.log("afterRemoveLiquidity called");
        
         uint256 pointsForRemovingLiquidity = uint256(int256(-delta.amount0()));
         console.log("points removed", pointsForRemovingLiquidity);
        
        require(providerPoints[sender] >= pointsForRemovingLiquidity, "invalid operation");

        providerPoints[sender] = providerPoints[sender] - pointsForRemovingLiquidity;
        

        return (BaseHook.afterRemoveLiquidity.selector, delta);
    }

    /// @notice V4 decides whether to invoke specific hooks by inspecting the least significant bits
    /// of the address that the hooks contract is deployed to.
    /// For example, a hooks contract deployed to address: 0x0000000000000000000000000000000000002400
    /// has the lowest bits '10 0100 0000 0000' which would cause the 'before initialize' and 'after add liquidity' hooks to be used.
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: true,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: true,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }
}
