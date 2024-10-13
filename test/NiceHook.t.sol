// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {NiceHook} from "../src/NiceHook.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Constants} from "v4-core/test/utils/Constants.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {EasyPosm} from "./utils/EasyPosm.sol";
import {Fixtures} from "./utils/Fixtures.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";

contract NiceHookTest is Test, Fixtures {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    NiceHook hook;
    PoolId poolId;

    uint256 tokenId;

    address alice = address(0x1111000000000000000000000000000000000000);
    address bob = address(0x2222000000000000000000000000000000000000);
    address eve = address(0x99900000000000000000000000000000000000);

    function setUp() public {
        // creates the pool manager, utility routers, and test tokens
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        deployAndApprovePosm(manager);

        // Deploy the hook to an address with the correct flags    
        address flags = address(
            uint160(
             Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG 
            ) ^ (0x4444 << 144) // Namespace the hook to avoid collisions
        );
        bytes memory constructorArgs = abi.encode(manager); //Add all the necessary constructor arguments from the hook
        deployCodeTo("NiceHook.sol:NiceHook", constructorArgs, flags);
        hook = NiceHook(flags);

        // Create the pool
        key = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        poolId = key.toId();
        manager.initialize(key, SQRT_PRICE_1_1, ZERO_BYTES);

        // Provideliquidity to the pool
        int24 tickLower = TickMath.minUsableTick(key.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(key.tickSpacing);

        uint128 liquidityAmount = 1000000e18;
        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidityAmount
        );

        (tokenId,) = posm.mint(
            key,
            tickLower,
            tickUpper,
            liquidityAmount,
            amount0Expected + 1,
            amount1Expected + 1,
            address(this),
            block.timestamp,
            ZERO_BYTES
        );

        (tokenId,) = posm.mint(
            key,
            -600,
            600,
            liquidityAmount,
            amount0Expected + 1,
            amount1Expected + 1,
            address(this),
            block.timestamp,
            ZERO_BYTES
        );
    }

    function testSimple() public {
        // add tokens to the users
        NiceHook(hook).setKYCEnabled(false);
        NiceHook(hook).setSandwichProtected(false);

        key.currency0.transfer(address(alice), 1000 * 10 ** 18);
        key.currency1.transfer(address(alice), 1000 * 10 ** 18);
        _setApprovalsFor(alice, address(Currency.unwrap(key.currency0)));
        _setApprovalsFor(alice, address(Currency.unwrap(key.currency1)));

        uint256 userBalanceBefore0 = currency0.balanceOf(address(alice));
        uint256 userBalanceBefore1 = currency1.balanceOf(address(alice));
        console2.log("ALICE [0] before swapping: ", userBalanceBefore0);
        console2.log("ALICE [1] before swapping: ", userBalanceBefore1);

        vm.prank(alice);
        // Perform a test swap //
        bool zeroForOne = true; //true = buy, false = sell
        int256 amountSpecified = -10 ether; // negative number indicates exact input swap!
        BalanceDelta swapDelta = swap(key, zeroForOne, amountSpecified, ZERO_BYTES);

        assertEq(int256(swapDelta.amount0()), amountSpecified);
        uint256 userBalanceAfter0 = currency0.balanceOf(address(alice));
        uint256 userBalanceAfter1 = currency1.balanceOf(address(alice));
        console2.log("ALICE [0] after swapping: ", userBalanceAfter0);
        console2.log("ALICE [1] after swapping: ", userBalanceAfter1);
        assertEq(int256(swapDelta.amount0()), amountSpecified);
        assertGt(userBalanceAfter1, userBalanceBefore1);
    }

    function testBuyFeeOverLimit() public {
        vm.expectRevert();
        NiceHook(hook).setBuyFee(100000);
    }

    function testWhitelist() public {
        // positions were created in setup()
        // add tokens to the users

        NiceHook(hook).setKYCEnabled(true);
        NiceHook(hook).setMerkleRoot(0x94a66a14ffa68ca771258e789aa59ccc467ba0b3244a6b0ef1683f40d96c5c0a);

        key.currency0.transfer(address(alice), 1000 * 10 ** 18);
        key.currency1.transfer(address(alice), 1000 * 10 ** 18);
        key.currency0.transfer(address(bob), 1000 * 10 ** 18);
        key.currency1.transfer(address(bob), 1000 * 10 ** 18);

        _setApprovalsFor(alice, address(Currency.unwrap(key.currency0)));
        _setApprovalsFor(alice, address(Currency.unwrap(key.currency1)));
        _setApprovalsFor(bob, address(Currency.unwrap(key.currency0)));
        _setApprovalsFor(bob, address(Currency.unwrap(key.currency1)));

        uint256 userBalanceBefore0 = currency0.balanceOf(address(alice));
        uint256 userBalanceBefore1 = currency1.balanceOf(address(alice));

        console2.log("ALICE balance in currency0 before swapping: ", userBalanceBefore0);
        console2.log("ALICE balance in currency1 before swapping: ", userBalanceBefore1);

        vm.prank(alice);

        // Perform a test swap //
        bool zeroForOne = true;
        int256 amountSpecified = -1e18; // negative number indicates exact input swap!

        bytes32[] memory proof = new bytes32[](2);
        proof[0] = 0x0808efdc750a8f87b105314e0110fb89feefe2fc5b5c382863f63cba02005088;
        proof[1] = 0xf78d5c92338bdd84d36b56e4e74881e5ead16c527f84121d0c77d8951ca62953;
        bytes memory hookData = abi.encode(address(alice), proof);
        BalanceDelta swapDelta = swap(key, zeroForOne, amountSpecified, hookData);
        // ------------------- //

        assertEq(int256(swapDelta.amount0()), amountSpecified);

        uint256 userBalanceAfter0 = currency0.balanceOf(address(alice));
        uint256 userBalanceAfter1 = currency1.balanceOf(address(alice));

        console2.log("ALICE balance in currency0 after swapping: ", userBalanceAfter0);
        console2.log("ALICE balance in currency1 after swapping: ", userBalanceAfter1);
        assertGt(userBalanceAfter1, userBalanceBefore1);

        //bad proof reverts
        vm.prank(bob);
        proof = new bytes32[](2);
        proof[0] = 0xff08efdc750a8f87b105314e0110fb89feefe2fc5b5c382863f63cba02005088;
        proof[1] = 0xff8d5c92338bdd84d36b56e4e74881e5ead16c527f84121d0c77d8951ca62953;
        hookData = abi.encode(address(bob), proof);
        vm.expectRevert();
        swapDelta = swap(key, zeroForOne, amountSpecified, hookData);

        //no proof reverts
        vm.prank(bob);
        hookData = abi.encode(address(bob), new bytes32[](0));
        vm.expectRevert();
        swapDelta = swap(key, zeroForOne, amountSpecified, hookData);
    }

    function testDecayFeeAfterTime() public {
        // positions were created in setup()
        // add tokens to the users

        NiceHook(hook).setKYCEnabled(false);

        key.currency0.transfer(address(alice), 0);
        key.currency1.transfer(address(alice), 10 * 10 ** 18);
        key.currency0.transfer(address(bob), 0);
        key.currency1.transfer(address(bob), 10 * 10 ** 18);

        _setApprovalsFor(alice, address(Currency.unwrap(key.currency0)));
        _setApprovalsFor(alice, address(Currency.unwrap(key.currency1)));
        _setApprovalsFor(bob, address(Currency.unwrap(key.currency0)));
        _setApprovalsFor(bob, address(Currency.unwrap(key.currency1)));

        uint256 userBalanceBefore0 = currency0.balanceOf(address(alice));
        uint256 userBalanceBefore1 = currency1.balanceOf(address(alice));

        console2.log("ALICE balance in currency0 before swapping: ", userBalanceBefore0);
        console2.log("ALICE balance in currency1 before swapping: ", userBalanceBefore1);

        vm.prank(alice);

        // Perform a test swap //
        bool zeroForOne = false;
        int256 amountSpecified = -10 ether; // negative number indicates exact input swap!

        bytes memory hookData = abi.encode(address(alice), new bytes32[](0));
        BalanceDelta swapDelta = swap(key, zeroForOne, amountSpecified, hookData);

        uint256 userBalanceAfter0 = currency0.balanceOf(address(alice));
        uint256 userBalanceAfter1 = currency1.balanceOf(address(alice));

        console2.log("ALICE balance in currency0 after swapping: ", userBalanceAfter0);
        console2.log("ALICE balance in currency1 after swapping: ", userBalanceAfter1);

        //doing a swap after 6 days. 0.1% tax
        // Warp the block timestamp by 6 days (518400 seconds)
        vm.warp(block.timestamp + 518400);

        uint256 bobBalanceInitial0 = currency0.balanceOf(address(bob));
        uint256 bobBalanceInitial1 = currency1.balanceOf(address(bob));
        console2.log("BOB balance in currency0 initial: ", bobBalanceInitial0);
        console2.log("BOB balance in currency1 initial: ", bobBalanceInitial1);

        hookData = abi.encode(address(bob), new bytes32[](0));

        vm.prank(bob);
        swapDelta = swap(key, zeroForOne, amountSpecified, hookData);

        uint256 bobBalanceAfter0 = currency0.balanceOf(address(bob));
        uint256 bobBalanceAfter1 = currency1.balanceOf(address(bob));

        console2.log("BOB balance in currency0 after swapping: ", bobBalanceAfter0);
        console2.log("BOB balance in currency1 after swapping: ", bobBalanceAfter1);

        assertGt(bobBalanceAfter0, userBalanceAfter0);
    }

    function testSandwich() public {
        // positions were created in setup()
        // add tokens to the users

        NiceHook(hook).setKYCEnabled(false);
        NiceHook(hook).setSandwichProtected(true);

        key.currency0.transfer(address(eve), 100 * 10 ** 18);
        key.currency1.transfer(address(eve), 100 * 10 ** 18);
        _setApprovalsFor(eve, address(Currency.unwrap(key.currency0)));
        _setApprovalsFor(eve, address(Currency.unwrap(key.currency1)));

        uint256 userBalanceBefore0 = currency0.balanceOf(address(eve));
        uint256 userBalanceBefore1 = currency1.balanceOf(address(eve));

        console2.log("EVE balance in currency0 initial: ", userBalanceBefore0);
        console2.log("EVE balance in currency1 initial: ", userBalanceBefore1);

        vm.warp(block.timestamp + 518400);

        // Perform a test swap //
        bool zeroForOne = false;
        int256 amountSpecified = -10 ether; // negative number indicates exact input swap!

        bytes memory hookData = abi.encode(address(eve), new bytes32[](0));
        vm.prank(eve);
        BalanceDelta swapDelta = swap(key, zeroForOne, amountSpecified, hookData);
        vm.stopPrank();
        // ------------------- //

        uint256 userBalanceAfter0 = currency0.balanceOf(address(eve));
        uint256 userBalanceAfter1 = currency1.balanceOf(address(eve));

        console2.log("EVE balance in currency0 after 1st swap: ", userBalanceAfter0);
        console2.log("EVE balance in currency1 after 1st swap: ", userBalanceAfter1);

        zeroForOne = true; //swap back
        vm.prank(eve);
        swapDelta = swap(key, zeroForOne, amountSpecified, hookData);
        vm.stopPrank();
        // ------------------- //

        vm.warp(block.timestamp + 60);
        uint256 userBalanceAfterSecondSwap0 = currency0.balanceOf(address(eve));
        uint256 userBalanceAfterSecondSwap1 = currency1.balanceOf(address(eve));

        console2.log("EVE balance in currency0 after 2nd swap: ", userBalanceAfterSecondSwap0);
        console2.log("EVE balance in currency1 after 2nd swap: ", userBalanceAfterSecondSwap1);
    }

    function _setApprovalsFor(address _user, address token) internal {
        address[8] memory toApprove = [
            address(swapRouter),
            address(swapRouterNoChecks),
            address(modifyLiquidityRouter),
            address(modifyLiquidityNoChecks),
            address(donateRouter),
            address(takeRouter),
            address(claimsRouter),
            address(nestedActionRouter.executor())
        ];

        for (uint256 i = 0; i < toApprove.length; i++) {
            vm.prank(_user);
            MockERC20(token).approve(toApprove[i], Constants.MAX_UINT256);
        }
    }
}
