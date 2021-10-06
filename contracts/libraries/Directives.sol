// SPDX-License-Identifier: Unlicensed

pragma solidity >=0.8.4;
pragma experimental ABIEncoderV2;

import "./SafeCast.sol";

/* @title Pool directive library */
library Directives {
    using SafeCast for int256;
    using SafeCast for uint256;

    struct SwapDirective {
        uint8 liqMask_;
        bool isBuy_;
        bool inBaseQty_;
        uint128 qty_;
        uint128 limitPrice_;
    }
    
    struct ConcentratedDirective {
        int24 openTick_;
        ConcenBookend[] bookends_;
    }
    
    struct ConcenBookend {
        int24 closeTick_;
        int256 liquidity_;
    }

    struct AmbientDirective {
        int256 liquidity_;
    }

    struct PassiveDirective {
        AmbientDirective ambient_;
        ConcentratedDirective[] conc_;
    }
    
    struct PoolDirective {
        uint24 poolIdx_;
        PassiveDirective passive_;
        SwapDirective swap_;
        PassiveDirective passivePost_;
    }

    struct RolloverDirective {
        uint24 poolIdx_;
        uint8 liqMask_;
        uint128 limitPrice_;
    }

    struct SettlementChannel {
        address token_;
        int256 limitQty_;
        uint256 dustThresh_;
        bool useReserves_;
    }

    struct HopDirective {
        PoolDirective[] pools_;
        SettlementChannel settle_;
    }

    struct OrderDirective {
        SettlementChannel open_;
        HopDirective[] hops_;
    }


    function useRollover (RolloverDirective memory dir) internal pure returns (bool) {
        return dir.limitPrice_ > 0;
    }
    
    function stubRollover (RolloverDirective memory dir,
                           int256 rolledFlow, bool inBase) internal pure returns
        (uint24 poolIdx, SwapDirective memory swap) {
        poolIdx = dir.poolIdx_;
        bool isBuy = inBase ?
            rolledFlow < 0 : rolledFlow > 0; // Verify direction
        uint128 qty = rolledFlow.toUint256().toUint128();
        swap = SwapDirective({liqMask_: dir.liqMask_, isBuy_: isBuy,
                    inBaseQty_: inBase, qty_: qty,
                    limitPrice_: dir.limitPrice_});
    }

}
