// SPDX-License-Identifier: Unlicensed

pragma solidity >=0.8.4;
pragma experimental ABIEncoderV2;

import '../libraries/TickMath.sol';
import '../libraries/FixedPoint.sol';
import '../libraries/LiquidityMath.sol';
import '../libraries/SafeCast.sol';
import '../libraries/LowGasSafeMath.sol';
import '../libraries/PoolSpecs.sol';
import '../libraries/CurveMath.sol';
import '../libraries/CurveCache.sol';

import "hardhat/console.sol";

/* @title Liquidity Curve Mixin
 * @notice Tracks the state of the locally stable constant product AMM liquid curve
 *         for the pool. Applies any adjustment to the curve as needed, either from
 *         new or removed positions or pre-determined liquidity bumps that occur
 *         when crossing tick boundaries. */
contract LiquidityCurve {
    using SafeCast for uint128;
    using SafeCast for uint192;
    using SafeCast for uint144;
    using CurveMath for uint128;
    using CurveMath for CurveMath.CurveState;
    using CurveCache for CurveCache.Cache;
    
    mapping(bytes32 => CurveMath.CurveState) private curves_;

    /* @notice Copies the current state of the curve in EVM storage to a memory clone.
     * @dev    Use for light-weight gas ergonomics when iterarively operating on the 
     *         curve. But it's the callers responsibility to persist the changes back
     *         to storage when complete. */
    function snapCurve (bytes32 poolIdx) view internal returns
        (CurveMath.CurveState memory curve) {
        curve = curves_[poolIdx];
        require(curve.priceRoot_ > 0, "J");
    }

    function snapCurveInit (bytes32 poolIdx) view internal returns
        (CurveMath.CurveState memory) {
        return curves_[poolIdx];
    }

    /* @notice Writes a CurveState modified in memory back into persistent storage. 
     *         Use for the working copy from snapCurve when finalized. */
    function commitCurve (bytes32 poolIdx, CurveMath.CurveState memory curve)
        internal {
        curves_[poolIdx] = curve;
    }
    
    /* @notice Called whenever a user adds a fixed amount of concentrated liquidity
     *         to the curve. This must be called regardless of whether the liquidity is
     *         in-range at the current curve price or not.
     * @dev After being called this will alter the curve to reflect the new liquidity, 
     *      but it's the callers responsibility to make sure that the required 
     *      collateral is actually collected.
     *
     * @param poolIdx   The index of the pool applied to
     * @param liquidity The amount of liquidity being added. Represented in the form of
     *                  sqrt(X*Y) where X,Y are the virtual reserves of the tokens in a
     *                  constant product AMM. Calculate the same whether in-range or not.
     * @param lowerTick The tick index corresponding to the bottom of the concentrated 
     *                  liquidity range.
     * @param upperTick The tick index corresponding to the bottom of the concentrated 
     *                  liquidity range.
     *
     * @return base - The amount of base token collateral that must be collected 
     *                following the addition of this liquidity.
     * @return quote - The amount of quote token collateral that must be collected 
     *                 following the addition of this liquidity. */
    function liquidityReceivable (CurveCache.Cache memory curve, uint128 liquidity,
                                  int24 lowerTick, int24 upperTick)
        internal pure returns (uint128, uint128) {
        (uint128 base, uint128 quote, bool inRange) =
            liquidityFlows(curve, liquidity, lowerTick, upperTick);
        bumpConcentrated(curve, liquidity, inRange);
        return chargeConservative(base, quote, inRange);
    }

    /* @notice Equivalent to above, but used when adding non-range bound constant 
     *         product ambient liquidity.
     * @dev Like above, it's the caller's responsibility to collect the necessary 
     *      collateral to add to the pool.

     * @param seeds The number of ambient seeds being added. Note that this is 
     *              denominated as seeds *not* liquidity. The amount of liquidity
     *              contributed will be based on the current seed->liquidity conversion
     *              rate on the curve. (See CurveMath.sol.) */
    function liquidityReceivable (CurveCache.Cache memory curve, uint128 seeds) 
        internal pure returns (uint128, uint128) {
        (uint128 base, uint128 quote) = liquidityFlows(curve, seeds);
        bumpAmbient(curve, seeds);
        return chargeConservative(base, quote, true);
    }

    /* @notice Called when liquidity is being removed from the pool Adjusts the curve
     *         accordingly and calculates the amount of collateral payable to the user.
     *         This must be called for all removes regardless of whether the liquidity
     *         is in range or not.
     * @dev It's the caller's responsibility to actually return the collateral to the 
     *      user. This method will only calculate what's owed, but won't actually pay it.
     *
     * @param poolIdx   The index of the pool applied to
     * @param liquidity The amount of liquidity being removed, whether in-range or not.
     *                  Represented in the form of sqrt(X*Y) where x,Y are the virtual
     *                  reserves of a constant product AMM.
     * @param rewardRate The total cumulative earned but unclaimed rewards on the staked
     *                   liquidity. Used to increment the payout with the rewards, and
     *                   burn the ambient liquidity tied to the rewards. (See 
     *                   CurveMath.sol for more.) Represented as a 128-bit fixed point
     *                   cumulative growth rate of ambient seeds per unit of liquidity.
     * @param lowerTick The tick index corresponding to the bottom of the concentrated 
     *                  liquidity range.
     * @param upperTick The tick index corresponding to the bottom of the concentrated 
     *                  liquidity range.
     *
     * @return base - The amount of base token collateral that can be paid out following
     *                the removal of the liquidity. Always rounded down to favor 
     *                collateral stability.
     * @return quote - The amount of base token collateral that can be paid out following
     *                the removal of the liquidity. Always rounded down to favor 
     *                collateral stability. */
    function liquidityPayable (CurveCache.Cache memory curve, uint128 liquidity,
                               uint64 rewardRate, int24 lowerTick, int24 upperTick)
        internal pure returns (uint128 base, uint128 quote) {
        (base, quote) = liquidityPayable(curve, liquidity, lowerTick, upperTick);

        if (rewardRate > 0) {
            // Round down reward sees on payout, in contrast to rounding them up on
            // incremental accumulation (see CurveAssimilate.sol). This mathematicaly
            // guarantees that we never try to burn more tokens than exist on the curve.
            uint128 rewards = FixedPoint.mulQ48(liquidity, rewardRate).toUint128By144();
            
            if (rewards > 0) {
                (uint128 baseRewards, uint128 quoteRewards) =
                    liquidityPayable(curve, rewards.toUint128());
                base += baseRewards;
                quote += quoteRewards;
            }
        }
    }

    /* @notice The same as the above liquidityPayable() but called when accumulated 
     *         rewards are zero. */
    function liquidityPayable (CurveCache.Cache memory curve, uint128 liquidity,
                               int24 lowerTick, int24 upperTick)
        internal pure returns (uint128 base, uint128 quote) {
        bool inRange;
        (base, quote, inRange) = liquidityFlows(curve, liquidity,
                                                lowerTick, upperTick);
        bumpConcentrated(curve, -(liquidity.toInt128Sign()), inRange);
    }

    /* @notice Same as above liquidityPayable() but used for non-range based ambient
     *         constant product liquidity.
     *
     * @param poolIdx   The index of the pool applied to
     * @param seeds The number of ambient seeds being added. Note that this is 
     *              denominated as seeds *not* liquidity. The amount of liquidity
     *              contributed will be based on the current seed->liquidity conversion
     *              rate on the curve. (See CurveMath.sol.) 
     * @return base - The amount of base token collateral that can be paid out following
     *                the removal of the liquidity. Always rounded down to favor 
     *                collateral stability.
     * @return quote - The amount of base token collateral that can be paid out following
     *                the removal of the liquidity. Always rounded down to favor 
     *                collateral stability. */
    function liquidityPayable (CurveCache.Cache memory curve, uint128 seeds)
        internal pure returns (uint128 base, uint128 quote) {
        (base, quote) = liquidityFlows(curve, seeds);
        bumpAmbient(curve, -(seeds.toInt128Sign()));
    }

    function bumpAmbient (CurveCache.Cache memory curve, uint128 seedDelta)
        private pure {
        bumpAmbient(curve, seedDelta.toInt128Sign());
    }

    function bumpAmbient (CurveCache.Cache memory curve, int128 seedDelta) private pure {
        curve.curve_.liq_.ambientSeed_ =
            LiquidityMath.addDelta(curve.curve_.liq_.ambientSeed_, seedDelta);
    }

    function bumpConcentrated (CurveCache.Cache memory curve,
                               uint128 liqDelta, bool inRange) private pure {
        bumpConcentrated(curve, int128(uint128(liqDelta)), inRange);
    }
    
    function bumpConcentrated (CurveCache.Cache memory curve,
                               int128 liqDelta, bool inRange) private pure {
        if (inRange) {
            curve.curve_.liq_.concentrated_ =
                LiquidityMath.addDelta(curve.curve_.liq_.concentrated_, liqDelta);
        }
    }
    

    /* @dev Uses fixed-point math that rounds down up to 2 wei from the true real valued
     *   flows. Safe to pay this flow, but when pool is receiving caller must make sure
     *   to round up for collateral safety. */
    function liquidityFlows (CurveCache.Cache memory curve, uint128 liquidity,
                             int24 bidTick, int24 askTick)
        private pure returns (uint128 baseDebit, uint128 quoteDebit, bool inRange) {
        int24 priceTick = curve.pullPriceTick();
        (uint128 bidPrice, uint128 askPrice) =
            translateTickRange(bidTick, askTick);

        if (priceTick < bidTick) {
            quoteDebit = liquidity.deltaQuote(bidPrice, askPrice);
        } else if (priceTick >= askTick) {
            baseDebit = liquidity.deltaBase(bidPrice, askPrice);
        } else {
            quoteDebit = liquidity.deltaQuote(curve.curve_.priceRoot_, askPrice);
            baseDebit = liquidity.deltaBase(bidPrice, curve.curve_.priceRoot_);
            inRange = true;
        }
    }
    
    /* @dev Uses fixed-point math that rounds down at each division. Because there are
     *   divisions, max precision loss is under 2 wei. Safe to pay this flow, but when
     *   when pool is receiving, caller must make sure to round up for collateral 
     *   safety. */
    function liquidityFlows (CurveCache.Cache memory curve, uint128 seeds)
        private pure returns (uint128 baseDebit, uint128 quoteDebit) {
        uint128 liq = CompoundMath.inflateLiqSeed
            (seeds, curve.curve_.accum_.ambientGrowth_);
        baseDebit = FixedPoint.mulQ64(liq, curve.curve_.priceRoot_).toUint128By192();
        quoteDebit = FixedPoint.divQ64(liq, curve.curve_.priceRoot_).toUint128By192();
    }

    /* @notice Called exactly once at the initializing of the pool. Initializes the
     *         liquidity curve at an arbitrary price.
     * @dev Throws error if price was already initialized. 
     *
     * @param poolIdx   The index of the pool applied to
     * @param priceRoot - Square root of the price. Represented as 96-bit fixed point. */
    function initPrice (CurveCache.Cache memory curve, uint128 priceRoot)
        internal pure {
        require(curve.curve_.priceRoot_ == 0, "N");
        curve.curve_.priceRoot_ = priceRoot;
    }

    function translateTickRange (int24 lowerTick, int24 upperTick)
        private pure returns (uint128 bidPrice, uint128 askPrice) {
        require(upperTick > lowerTick, "O");
        require(lowerTick >= TickMath.MIN_TICK, "I");
        require(upperTick <= TickMath.MAX_TICK, "X");
        bidPrice = TickMath.getSqrtRatioAtTick(lowerTick);
        askPrice = TickMath.getSqrtRatioAtTick(upperTick);
    }

    // Need to support at least 2 wei of precision round down when calculating quote
    // token reserve deltas. (See CurveMath's deltaPriceQuote() function.) 4 gives us a
    // safe cushion and is economically meaningless.
    uint8 constant TOKEN_ROUND = 4;
    
    function chargeConservative (uint128 liqBase, uint128 liqQuote, bool inRange)
        private pure returns (uint128, uint128) {
        return ((liqBase > 0 || inRange) ? liqBase + TOKEN_ROUND : 0,
                (liqQuote > 0 || inRange) ? liqQuote + TOKEN_ROUND : 0);
    }
}
